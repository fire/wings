%%--------------------------------------------------------------------
%%
%%  wings_osp.erl --
%%
%%     Ray-tracing renderer with ospray
%%
%%  Copyright (c) 2015 Dan Gudmundsson
%%
%%  See the file "license.terms" for information on usage and redistribution
%%  of this file, and for a DISCLAIMER OF ALL WARRANTIES.
%%
-module(wings_osp).
-behaviour(gen_server).

-compile([export_all, nowarn_export_all]).
-include("wings.hrl").
-include_lib("wings/e3d/e3d_image.hrl").

-on_load(reload/0).

%% API
-export([render/1, render/2, menu/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, format_status/2]).

-export([wings_event/2]).

-define(SERVER, ?MODULE).

%%%===================================================================
%%% API
%%%===================================================================

menu() ->
    {"OSPray...", wings_osp}.

-spec render(#st{}) -> 'keep'.
render(St) ->
    %% Should display options and recurse but for now
    render(St, []).

-spec render(#st{}, [any()]) -> 'keep'.
render(#st{shapes=Sh, mat=Materials} = St, Opts) ->
    %% Should work on objects but wings_draw_setup:we/3 needs we{} for now
    Pid = start_link(),
    Subdiv = proplists:get_value(subdivisions, Opts, 0),
    Stash = #{opts=>Opts, subdiv=>Subdiv, st=>St, pid=>Pid},
    ok = gen_server:call(Pid, cancel_prev_render),
    Camera = [ {wings_pref:get_value(negative_width),wings_pref:get_value(negative_height)}
             | wpa:camera_info([pos_dir_up, fov, distance_to_aim])],
    send({camera, Camera}, Stash),
    send({materials, Materials}, Stash),
    Wes = gb_trees:values(Sh),
    lists:foldl(fun prepare_mesh/2, Stash, Wes),
    send(render, Stash),
    keep.

prepare_mesh(We, Stash) when ?IS_VISIBLE(We#we.perm), ?IS_ANY_LIGHT(We) ->
    %% case IsLight of
    %%     true when not ?IS_POINT_LIGHT(We) ->
    %%         %% Don't subdiv area, ambient and infinite lights
    %%         {0, pbr_light:lookup_id(Name,Ls)};
    %%     true -> %% Subdiv the point lights to be round
    %%         {3, pbr_light:lookup_id(Name,Ls)};
    %%         false ->
    %%         {proplists:get_value(subdivisions, Opts, 1),false}
    %% end,
    Stash;
prepare_mesh(#we{id=Id}=We, #{st:=St, subdiv:=SubDiv} = Stash) when ?IS_VISIBLE(We#we.perm) ->
    Options = [{smooth, true}, {subdiv, SubDiv}],
    Vab = wings_draw_setup:we(We, Options, St),
    %% I know something about this implementation :-)
    try Vab of
	#vab{data=Bin, sn_data=Ns, face_vs=Vs, face_vc=Vc, face_uv=Uv, mat_map=MatMap} ->
            send({mesh, #{id=>Id, bin=>Bin, vs=>Vs, ns=>Ns, vc=>Vc, uv=>Uv, mm=>MatMap}}, Stash),
            Stash
    catch _:badmatch ->
	    erlang:error({?MODULE, vab_internal_format_changed})
    end;
prepare_mesh(_We, Stash) ->
    %% ?dbg("Perm = ~p ~p~n", [_We#we.perm, ?IS_VISIBLE(_We#we.perm)]),
    Stash.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%  Start window (and event listener)

start_link() ->
    Pid = case gen_server:start_link({local, ?SERVER}, ?MODULE, [], []) of
              {ok, New} -> New;
              {error, {already_started, Old}} -> Old;
              Error -> error(Error)
          end,
    case wings_wm:is_window(?MODULE) of
	true -> Pid;
	false ->
	    Op = {seq, push, fun(Ev) -> wings_event(Ev, #{pid=>Pid}) end},
	    wings_wm:new(?MODULE, {0,0,1}, {0,0}, Op),
	    wings_wm:hide(?MODULE),
	    %%wings_wm:set_dd(?MODULE, geom_display_lists),
            Pid
    end.

%% wings_event({note, image_change}, Pid, State) ->
%%     case [Im || {Id, Im} <- wings_image:images(), WinId =:= Id] of
%%         [Image] -> wx_object:cast(Window, {image_change, Image});
%%         _ -> ignore
%%     end,
%%     keep;
wings_event({render_image, Sz, Image}, State0) ->
    State = update_image(Image, Sz, State0),
    {replace, fun(Ev) -> ?MODULE:wings_event(Ev, State) end};
wings_event(update_fun, State) ->
    {replace, fun(Ev) -> ?MODULE:wings_event(Ev, State) end};
wings_event(_Ev, _State) ->
    ?dbg("Got Ev ~P~n", [_Ev, 20]),
    keep.

update_image(Image, {W,H}, State) ->
    Name = ?__(1, "OSPRAY render"),
    E3DImage = #e3d_image{type=r8g8b8a8, bytes_pp=4,
                          width=W, height=H, image=Image},
    Id = case maps:get(image, State, undefined) of
             undefined ->
                 wings_image:new_temp(Name, E3DImage);
             Old ->
                 case wings_image:update(Old, E3DImage) of
                     ok -> Old;
                     %% oops render was deleted
                     error -> wings_image:new_temp(Name, E3DImage)
                 end
         end,
    wings_image:window(Id),
    State#{image => Id}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%% Below here is render server process

init([]) ->
    %% process_flag(trap_exit, false),
    add_priv_path(),   %% Must be done before osp:init/1 otherwise we can't load the nif
    Dev = osp:init(),
    no_error = osp:deviceGetLastErrorCode(Dev),
    {ok, reset(#{dev=>Dev, sz_w=>1000})}.

handle_call(cancel_prev_render, _From, State) ->
    case maps:get(render, State, false) of
        false ->
            {reply, ok, State};
        #{future:=Future} ->
            osp:cancel(Future),
            {reply, ok, reset(State)}
    end.

handle_cast({mesh, Request}, #{meshes:=Ms, materials:=Mats0} = State) ->
    %% ?dbg("~P~n", [Request,20]),
    {Mesh, Mats} = make_geom(Request, Mats0),
    no_error = osp:deviceGetLastErrorCode(maps:get(dev, State)),
    {noreply, State#{meshes:=[Mesh|Ms], materials:=Mats}};
handle_cast({camera, [{NW,NH}, {Pos,Dir,Up}, Fov, Dist]}, #{sz_w:=W} = State) ->
    H = round(W*NH/NW),
    Camera = osp:newCamera(perspective),
    osp:setFloat(Camera, "aspect", W / H),
    osp:setParam(Camera, "position", vec3f, Pos),
    osp:setParam(Camera, "direction", vec3f, Dir),
    osp:setParam(Camera, "up", vec3f, Up),
    osp:setParam(Camera, "fovy", float, Fov),
    osp:setParam(Camera, "focusDistance", float, Dist),
    ?dbg("Camera dist ~p~n",[Dist]),
    osp:setParam(Camera, "apertureRadius", float, Dist/100.0),
    osp:commit(Camera),
    {noreply, State#{camera=>Camera, sz=>{W,H}}};
handle_cast({materials, Materials0}, State) ->
    Materials = prepare_materials(gb_trees:to_list(Materials0)),
    {noreply, State#{materials => Materials}};
handle_cast(render, State0) ->
    ?dbg("Start render: ~p~n",[time()]),
    try {noreply, render_start(State0)}
    catch _:Reason:ST ->
            ?dbg("Crash: ~P ~P~n",[Reason,20, ST,20]),
            {stop, normal}
    end;
handle_cast(What, State) ->
    ?dbg("unexpected msg: ~p~n",[What]),
    {noreply, State}.

handle_info({osp, Future, task_finished}, #{render:=#{future:=Future}} = State0) ->
    State = render_done(State0),
    {noreply, State};
handle_info(_Info, State) ->
    ?dbg("unexpected info: ~p~n",[_Info]),
    {noreply, State}.

terminate(_Reason, _State) ->
    ok.

format_status(_Opt, Status) ->
    Status.

%%%===================================================================
%%% Internal functions
%%%===================================================================

reset(State) ->
    maps:remove(render, State#{meshes=>[], materials=>[]}).

render_start(#{meshes := []} = State) ->
    State;
render_start(#{meshes := Ms, camera := Camera, sz:= {W,H}, dev := Dev} = State) ->
    no_error = osp:deviceGetLastErrorCode(Dev),
    Meshes = [Geom || #{geom:=Geom} <- Ms],
    ?dbg("Meshes: ~w ~n", [length(Ms)]),
    Group = osp:newGroup(),
    ModelList = osp:newCopiedData(Meshes, geometric_model, length(Meshes)),
    osp:setParam(Group, "geometry", geometric_model, ModelList),
    osp:commit(Group),
    Instance = osp:newInstance(Group),
    osp:commit(Instance),
    World = osp:newWorld(),
    osp:setParam(World, "instance", instance, osp:newCopiedData([Instance], instance, 1)),

    Light = osp:newLight("sunSky"),
    osp:setParam(Light, up, vec3f, e3d_vec:norm({0.2,1.0,0.2})),
    osp:setParam(Light, direction, vec3f, e3d_vec:norm({-0.2,-1.0,-0.2})),
    osp:commit(Light),
    osp:setParam(World, "light", light, osp:newCopiedData([Light], light, 1)),
    osp:commit(World),

    ?dbg("~p~n", [osp:deviceGetLastErrorCode(Dev)]),
    Renderer = osp:newRenderer("pathtracer"), %% choose path tracing renderer
    osp:setParam(Renderer, "backgroundColor", vec4f, {1,1,1,0.0}),
    osp:setParam(Renderer, "pixelSamples", int, 2), %% Per Pixel and pass
    osp:setParam(Renderer, "varianceThreshol", float, 0.1),
    MaterialsData = setup_materials(maps:get(materials, State)),
    osp:setObject(Renderer, "material", MaterialsData),
    osp:commit(Renderer),

    Framebuffer = osp:newFrameBuffer(W,H, fb_srgba, [fb_color, fb_accum, fb_variance]),
    osp:resetAccumulation(Framebuffer),
    ?dbg("~p~n", [osp:deviceGetLastErrorCode(Dev)]),
    Future = osp:renderFrame(Framebuffer, Renderer, Camera, World),
    T0 = erlang:system_time(),
    RenderOpts = #{fs=>0, t0=>T0, time=>T0, wait=>1, %% stats
                   future=>Future, fb=>Framebuffer, render=>Renderer, cam=>Camera, world=>World},
    osp:subscribe(Future),
    State#{render => RenderOpts}.

render_done(#{render:=Render, sz:={W,H}=Sz} = State) ->
    #{time := T0, wait:=Wait0, fs:=N,
      fb:=Framebuffer, render:=Renderer, cam:=Camera, world:=World} = Render,
    Now = erlang:system_time(),
    Expired = erlang:convert_time_unit(Now-T0, native, seconds) >= Wait0,
    {T1, Wait} = case Expired of
                     true ->
                         Image = osp:readFrameBuffer(Framebuffer, W,H, fb_srgba, fb_color),
                         wings_wm:psend(?MODULE, {render_image, Sz, Image}),
                         {Now, Wait0 + 2};
                     false ->
                         {T0, Wait0}
                 end,
    case Wait < 10 of
        true ->
            F = osp:renderFrame(Framebuffer, Renderer, Camera, World),
            osp:subscribe(F),
            State#{render := Render#{fs:=N+1, time:=T1, wait:=Wait, future:=F}};
        false ->
            Total = erlang:convert_time_unit(Now - maps:get(t0,Render), native, millisecond),
            ?dbg("Image rendered ~w frames in ~ws (~f)~n", [N, Total div 1000, N/Total]),
            reset(State)
    end.

make_geom(#{id:=Id, bin:=Data, ns:=NsBin, vs:=Vs, vc:=Vc, uv:=Uv, mm:=MM} = _Input, Mats0) ->
    {Stride, 0} = Vs,
    %% Asserts
    N = byte_size(Data) div Stride,
    0 = byte_size(Data) rem Stride,
    %% ?dbg("id:~p ~p ~p ~p ~p ~p~n",[Id, N, Vs, Vc, Uv, MM]),
    Mesh = osp:newGeometry("mesh"),
    {MatIds, UseVc, Mats} = make_material_index(MM, Mats0),

    add_data(Mesh, Data, "vertex.position", vec3f, N, Vs),
    add_data(Mesh, Data, "vertex.texcoord", vec3f, N, Uv),
    add_vc_data(Mesh, Data, N, Vc, UseVc),
    add_data(Mesh, NsBin, "vertex.normal", vec3f, N),
    Index = lists:seq(0, N-1),
    IndexD  = osp:newCopiedData(Index, vec3ui, N div 3),  %% Triangles
    osp:setObject(Mesh, "index", IndexD),
    osp:commit(Mesh),
    Geom = osp:newGeometricModel(Mesh),
    add_mat(Geom, MatIds),
    osp:commit(Geom),
    {#{id=>Id, geom=>Geom}, Mats}.

%% Material handling

prepare_materials(Materials0) ->
    Mats = [prepare_mat(Mat) || Mat <- Materials0],
    Maps = maps:from_list(Mats),
    Maps#{'_next_id'=>0}.

prepare_mat({Name, Attrs0}) ->
    Maps = proplists:get_value(maps, Attrs0),
    Attrs1 = proplists:get_value(opengl, Attrs0),
    {value, {_, VC}, Attrs} = lists:keytake(vertex_colors, 1, Attrs1),
    {Name, maps:from_list([{maps,Maps}, {use_vc, VC /= ignore}|Attrs])}.

make_material_index([{Name,_,_,_}], Mats0) ->
    %% Single material per mesh
    get_mat_id(Name, Mats0);
make_material_index(MMS, Mats0) ->
    Sorted = lists:keysort(3, MMS),
    make_material_index(Sorted, false, Mats0, 0, []).

make_material_index([{Name,_,Start,N}|MMs],UseVc0,Mats0, Start, Acc) ->
    {Id, UseVc, Mats} = get_mat_id(Name,Mats0),
    %% Verts div by 3 to get triangle index
    MatIndex = make_mat_index(Id, N div 3),
    make_material_index(MMs, UseVc orelse UseVc0, Mats, Start+N, [MatIndex|Acc]);
make_material_index([], UseVc, Mats, N, Acc) ->
    Index = iolist_to_binary(lists:reverse(Acc)),
    Data = osp:newCopiedData(Index, uint, N div 3),
    {Data, UseVc, Mats}.

make_mat_index(Id, N) ->
    iolist_to_binary(lists:duplicate(N, <<Id:32/unsigned-native>>)).

get_mat_id(Name, #{'_next_id':= Next}=Mats0) ->
    #{use_vc:=UseVC} = Mat0 = maps:get(Name, Mats0),
    case maps:get(id, Mat0, undefined) of
        undefined ->
            Mat = Mat0#{id=>Next},
            {Next, UseVC, Mats0#{'_next_id':=Next+1, Name=>Mat}};
        Id ->
            {Id, UseVC, Mats0}
    end.

setup_materials(MatMap) ->
    Mats0 = maps:values(MatMap),
    MatRefs = lists:foldl(fun create_mat/2, [], Mats0),
    MatRefList = [Mat || {_, Mat} <- lists:keysort(1, MatRefs)],
    osp:newCopiedData(MatRefList, material, length(MatRefList)).

create_mat(#{id:=Id, diffuse:=Base, roughness:=Roughness, metallic:=Metallic, emission:=E}, Acc) ->
    {R,G,B,A} = Base,
    {ER,EB,EG,_} = E,
    if
        ER+EB+EG > 0.3 ->  %% Emissive material
            Mat = osp:newMaterial("luminous"),
            osp:setParam(Mat, "color", vec3f, wings_color:srgb_to_linear({ER,EG,EB})),
            osp:setParam(Mat, "transparency",   float, 1.0-A),
            %% osp:setParam(Mat, "intensity",   float, 1),
            osp:commit(Mat);
        %% A < 0.9 -> %% Glass
        %%     Mat = osp:newMaterial("thinGlass"),
        %%     %% osp:setParam(Mat, "color", vec3f, wings_color:srgb_to_linear({R,G,B})),
        %%     osp:setParam(Mat, "attenuationColor", vec3f, wings_color:srgb_to_linear({R,G,B})),
        %%     osp:setParam(Mat, "attenuationDistance",   float, 1.0),
        %%     osp:setParam(Mat, "thickness",   float, 0.05+A*A*A*4.0),
        %%     if A < 0.1 ->  %% Diamonds
        %%             osp:setParam(Mat, "eta", float, 2.5);
        %%        A < 0.3 ->  %% ???
        %%             osp:setParam(Mat, "eta", float, 2.0);
        %%        A ->  %% Glass
        %%             osp:setParam(Mat, "eta", float, 1.5);
        %%        true -> ok
        %%     end,
        %%     osp:commit(Mat);
        true ->
            Mat = osp:newMaterial("principled"),
            osp:setParam(Mat, "metallic",  float, Metallic),
            osp:setParam(Mat, "roughness", float, Roughness),
            osp:setParam(Mat, "opacity",   float, A),
            osp:setParam(Mat, "ior",   float, 1.5),
            if  (A < 0.9) ->  %% Fake glass
                    osp:setParam(Mat, "transmission", float, 1.0-A),
                    osp:setParam(Mat, "transmissionDepth", float, 1.0),
                    osp:setParam(Mat, "transmissionColor", vec3f, wings_color:srgb_to_linear({R,G,B})),
                    osp:setParam(Mat, "thin", bool, true),
                    osp:setParam(Mat, "thickness",   float, 0.05+A*A*A*3.0),
                    osp:setParam(Mat, "backlight",   float, 2.0 - A*A*2);
                true ->
                    osp:setParam(Mat, "baseColor", vec3f, wings_color:srgb_to_linear({R,G,B}))
            end,
            osp:commit(Mat)
    end,
    [{Id, Mat}|Acc];
create_mat(_, Acc) ->
    Acc.

add_data(Obj, Data, Id, Type, N) ->
    add_data(Obj, Data, Id, Type, N, {0, 0}).
add_data(_Obj, _Data0, _Id, _Type, _N, none) ->
    ok;
add_data(Obj, Data0, Id, Type, N, {Stride, Start}) ->
    Data = case Start of
               0 -> Data0;
               _ ->
                   <<_:Start/binary, Data1/binary>> = Data0,
                   Data1
           end,
    Copied  = osp:newCopiedData(Data, Type, N, Stride),
    osp:commit(Copied),
    osp:setObject(Obj, Id, Copied).

add_mat(Geom, Id) when is_integer(Id) ->
    osp:setParam(Geom,  "material", uint, Id);
add_mat(Geom, IdsData) when is_reference(IdsData) ->
    osp:setObject(Geom, "material", IdsData).

add_vc_data(_Mesh, _Data, _N, none, _) ->
    ok;
add_vc_data(_Mesh, _Data, _N, _, false) ->
    ok;
add_vc_data(Mesh, Data, N, Vc, true) ->
    VcBin = rgb_to_rgba(Data, Vc),
    N = byte_size(VcBin) div 16,
    0 = byte_size(VcBin) rem 16,
    add_data(Mesh, VcBin, "vertex.color", vec4f, N).

rgb_to_rgba(Data0, {Stride, Start}) ->
    <<_:Start/binary, Data/binary>> = Data0,
    Skip = Stride - 12,
    rgb_to_rgba(Data,Skip, <<>>).

rgb_to_rgba(Data, SkipBytes, Acc) ->
    case Data of
        <<Cols:12/binary, _:SkipBytes/binary, Rest/binary>> ->
            rgb_to_rgba(Rest, SkipBytes, <<Acc/binary, Cols:12/binary, 1.0:32/float-native>>);
        <<Cols:12/binary, _/binary>> ->
            <<Acc/binary, Cols:12/binary, 1.0:32/float-native>>;
        <<>> ->
            Acc
    end.
%%

send(Cmd, #{pid := Pid}) ->
    gen_server:cast(Pid, Cmd).

add_priv_path() ->
    case os:type() of
        {win32, _} ->
            P0 = os_env:get("PATH"),
            OSPPath = filename:nativename(code:priv_dir(ospraye)),
            case string:find(P0, OSPPath) of
                nomatch ->
                    P1 = P0 ++ ";" ++ OSPPath,
                    io:format("Adding osp path: ~s~n", [P1]),
                    os_env:set("PATH", P1);
                _Where ->
                    io:format("osp path found: ~s~n", [_Where]),
                    ok
            end;
        _ ->
            P0 = os_env:get("LD_LIBRARY_PATH"),
            OSPPath = code:priv_dir(ospraye),
            case string:find(P0, OSPPath) of
                nomatch ->
                    P1 = P0 ++ ":" ++ OSPPath,
                    io:format("Adding osp path: ~s~n", [P1]),
                    os_env:set("PATH", P1);
                _ ->
                    ok
            end
    end.

reload() ->
    wings_wm:psend(?MODULE, update_fun),
    ok.
