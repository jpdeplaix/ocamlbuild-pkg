open Ocamlbuild_plugin

module LazyMonad = Ocamlbuild_pkg_LazyMonad
module META = Ocamlbuild_pkg_META
module Install = Ocamlbuild_pkg_Install
module List = struct
  include List
  include Ocamlbuild_pkg_List
end
module Options = Ocamlbuild_pkg_Options
module Mllib = Ocamlbuild_pkg_Mllib

open Ocamlbuild_pkg_Common
open LazyMonad.Operator

type modul = Pathname.t

let capitalized_module modul =
  Pathname.dirname modul / String.capitalize (Pathname.basename modul)

module Lib = struct
  type t = {
    name : string;
    dir : Pathname.t;
    modules : string list;
    private_modules : string list;
    backend : [`Native | `Byte] LazyMonad.t;
    subpackages : t list;
    mllib_packages : (Pathname.t * string list) list;
    meta : Pathname.t;
    meta_descr : META.t;
    files : Install.file list LazyMonad.t;
  }

  let create ~descr ~version ~requires ~name ~dir ~modules ?(private_modules=[]) ?backend ?(subpackages=[]) () =
    let backend = get_backend backend in
    let packages =
      let get_lib schema = schema.dir / schema.name in
      let rec aux schema =
        (get_lib schema, schema.modules, schema.private_modules) :: List.flat_map aux schema.subpackages
      in
      (dir / name, modules, private_modules) :: List.flat_map aux subpackages
    in
    let meta = dir / "META" in
    let meta_descr =
      let subpackages = List.map (fun x -> x.meta_descr) subpackages in
      META.create ~descr ~version ~requires ~name ~subpackages ()
    in
    let mllib_packages =
      List.map (fun (lib, m, pm) -> (lib, List.map capitalized_module (m @ pm))) packages
    in
    let files =
      backend >>= fun backend ->
      Options.tr_build meta >>= fun meta_file ->
      LazyMonad.List.float_map
        (fun (lib, _ , _) -> Options.tr_build lib >>= map_lib_exts backend)
        packages
      >>= fun libs ->
      LazyMonad.List.float_map
        (fun (_, modules, _) ->
           let aux m = Options.tr_build (dir / m) >>= map_mod_exts backend in
           LazyMonad.List.float_map aux modules
        )
        packages
      >|= fun modules ->
      List.map (Install.file ~check:`Check) (meta_file :: libs @ modules)
    in
    {
      name;
      dir;
      modules;
      private_modules;
      backend;
      subpackages;
      mllib_packages;
      meta;
      meta_descr;
      files;
    }

  let dispatcher {backend; mllib_packages; meta; meta_descr} hook =
    List.iter
      (fun (lib, modules) ->
         Mllib.dispatcher lib modules hook;
         if hook = After_options then begin
           let backend = LazyMonad.run hook backend in
           let mllib_exts = LazyMonad.run hook (map_mllib_exts lib) in
           let lib_exts = LazyMonad.run hook (map_lib_exts backend lib) in
           Options.targets @:= mllib_exts;
           Options.targets @:= lib_exts;
         end;
      )
      mllib_packages;
    META.dispatcher meta meta_descr hook;
    if hook = After_options then begin
      Options.targets @:= [meta];
    end
end

module Bin = struct
  type t = {
    main : Pathname.t;
    backend : [`Native | `Byte] LazyMonad.t;
    file : Install.file LazyMonad.t;
  }

  let ext_program = function
    | `Native -> "native"
    | `Byte -> "byte"

  let create ~main ?backend ?target () =
    let backend = get_backend backend in
    let target = get_target main target in
    let file =
      Options.exe >>= fun exe ->
      backend >>= fun backend ->
      let target = target ^ exe in
      Options.tr_build (main -.- ext_program backend) >|=
      Install.file ~check:`Check ~target
    in
    {
      main;
      backend;
      file;
    }

  let dispatcher {main; backend; file = _} hook = match hook with
    | After_options ->
        let backend = LazyMonad.run hook backend in
        Options.targets @:= [main -.- ext_program backend];
    | _ ->
        ()
end

type t = {
  eq : string -> bool;
  libs : Lib.t list;
  bins : Bin.t list;
  files : Install.dir list LazyMonad.t;
  install : Pathname.t;
}

let create ~name ?(libs=[]) ?(bins=[]) ?(files=[]) () =
  let install = name ^ ".install" in
  let files =
    LazyMonad.List.float_map (fun x -> x.Lib.files) libs >>= fun lib_files ->
    LazyMonad.List.map (fun x -> x.Bin.file) bins >|= fun bin_files ->
    Install.dir ~dir:"lib" lib_files ::
    Install.dir ~dir:"bin" bin_files ::
    files
  in
  let eq x = String.compare x name = 0 in
  {
    eq;
    libs;
    bins;
    files;
    install;
  }

let dispatcher {eq; libs; bins; files; install} hook =
  if hook = After_options then begin
    let len_cwd = String.length Pathname.pwd in
    let opt_build_dir = LazyMonad.run hook Options.build_dir in
    let len_build_dir = String.length opt_build_dir in
    let new_build_dir =
      if len_build_dir >= len_cwd
      && String.compare (String.sub opt_build_dir 0 len_cwd) Pathname.pwd = 0 then begin
        String.sub opt_build_dir len_cwd (len_build_dir - len_cwd)
        |> (^) Pathname.current_dir_name
        |> Pathname.normalize
      end else begin
        opt_build_dir
      end
    in
    Options.init_build_dir new_build_dir;
    if List.exists eq !Options.targets then begin
      Options.targets := List.filter (fun x -> not (eq x)) !Options.targets;
      LazyMonad.eval hook files;
    end;
  end;
  if LazyMonad.is_val files then begin
    List.iter (fun x -> Lib.dispatcher x hook) libs;
    List.iter (fun x -> Bin.dispatcher x hook) bins;
    let files = LazyMonad.run hook files in
    Install.dispatcher install files hook;
    if hook = After_options then begin
      Options.targets @:= [install];
    end;
  end
