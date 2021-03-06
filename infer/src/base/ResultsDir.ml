(*
 * Copyright (c) Facebook, Inc. and its affiliates.
 *
 * This source code is licensed under the MIT license found in the
 * LICENSE file in the root directory of this source tree.
 *)
open! IStd
open PolyVariantEqual
module L = Logging

let results_dir_dir_markers = [Config.results_dir ^/ Config.specs_dir_name]

let is_results_dir ~check_correct_version () =
  let not_found = ref "" in
  let has_all_markers =
    List.for_all results_dir_dir_markers ~f:(fun d ->
        Sys.is_directory d = `Yes
        ||
        ( not_found := d ^ "/" ;
          false ) )
    && ( (not check_correct_version)
       || Sys.is_file ResultsDatabase.database_fullpath = `Yes
       ||
       ( not_found := ResultsDatabase.database_fullpath ;
         false ) )
  in
  Result.ok_if_true has_all_markers ~error:(Printf.sprintf "'%s' not found" !not_found)


let non_empty_directory_exists results_dir =
  (* Look if [results_dir] exists and is a non-empty directory. If it's an empty directory, leave it
     alone. This allows users to create a temporary directory for the infer results without infer
     removing it to recreate it, which could be racy. *)
  Sys.is_directory results_dir = `Yes && not (Utils.directory_is_empty results_dir)


let remove_results_dir () =
  if non_empty_directory_exists Config.results_dir then (
    if not Config.force_delete_results_dir then
      Result.iter_error (is_results_dir ~check_correct_version:false ()) ~f:(fun err ->
          L.(die UserError)
            "ERROR: '%s' exists but does not seem to be an infer results directory: %s@\n\
             ERROR: Please delete '%s' and try again@." Config.results_dir err Config.results_dir ) ;
    Utils.rmtree Config.results_dir ) ;
  RunState.reset ()


let prepare_logging_and_db () =
  L.setup_log_file () ;
  PerfEvent.init () ;
  if Sys.is_file ResultsDatabase.database_fullpath <> `Yes then ResultsDatabase.create_db () ;
  ResultsDatabase.new_database_connection ()


let create_results_dir () =
  if non_empty_directory_exists Config.results_dir then
    RunState.load_and_validate ()
    |> Result.iter_error ~f:(fun error ->
           if Config.force_delete_results_dir then (
             L.user_warning "WARNING: %s@\n" error ;
             L.progress "Deleting results dir because --force-delete-results-dir was passed@." ;
             remove_results_dir () )
           else
             L.die UserError "ERROR: %s@\nPlease remove '%s' and try again" error Config.results_dir
       ) ;
  Unix.mkdir_p Config.results_dir ;
  Unix.mkdir_p Config.temp_dir ;
  List.iter ~f:Unix.mkdir_p results_dir_dir_markers ;
  prepare_logging_and_db () ;
  ()


let assert_results_dir advice =
  Result.iter_error (is_results_dir ~check_correct_version:true ()) ~f:(fun err ->
      L.(die UserError)
        "ERROR: No results directory at '%s': %s@\nERROR: %s@." Config.results_dir err advice ) ;
  RunState.load_and_validate ()
  |> Result.iter_error ~f:(fun error ->
         L.die UserError "%s@\nPlease remove '%s' and try again" error Config.results_dir ) ;
  prepare_logging_and_db () ;
  ()


let delete_capture_and_results_data () =
  DBWriter.reset_capture_tables () ;
  let dirs_to_delete =
    List.map
      ~f:(Filename.concat Config.results_dir)
      (Config.[classnames_dir_name] @ FileLevelAnalysisIssueDirs.get_registered_dir_names ())
  in
  List.iter ~f:Utils.rmtree dirs_to_delete ;
  ()


let scrub_for_caching () =
  let cache_capture =
    Config.genrule_mode || Option.exists Config.buck_mode ~f:BuckMode.is_clang_flavors
  in
  if cache_capture then DBWriter.canonicalize () ;
  (* make sure we are done with the database *)
  ResultsDatabase.db_close () ;
  let should_delete_dir =
    let dirs_to_delete =
      Config.
        [ captured_dir_name (* debug only *)
        ; classnames_dir_name (* a cache for the Java frontend *)
        ; temp_dir_name
          (* debug only *) ]
      @ (* temporarily needed to build report.json, safe to delete *)
      FileLevelAnalysisIssueDirs.get_registered_dir_names ()
    in
    List.mem ~equal:String.equal dirs_to_delete
  in
  let should_delete_file =
    let files_to_delete =
      (if cache_capture then [] else [ResultsDatabase.database_filename])
      @ [ Config.log_file
        ; (* some versions of sqlite do not clean up after themselves *)
          ResultsDatabase.database_filename ^ "-shm"
        ; ResultsDatabase.database_filename ^ "-wal" ]
    in
    let suffixes_to_delete = [".txt"; ".json"] in
    fun name ->
      (* Keep the JSON report and the JSON costs report *)
      (not
         (List.exists
            ~f:(String.equal (Filename.basename name))
            Config.
              [ report_json
              ; costs_report_json
              ; test_determinator_output
              ; export_changed_functions_output ]))
      && ( List.mem ~equal:String.equal files_to_delete (Filename.basename name)
         || List.exists ~f:(Filename.check_suffix name) suffixes_to_delete )
  in
  let rec delete_temp_results name =
    let rec cleandir dir =
      match Unix.readdir_opt dir with
      | Some entry ->
          if should_delete_dir entry then Utils.rmtree (name ^/ entry)
          else if
            not
              ( String.equal entry Filename.current_dir_name
              || String.equal entry Filename.parent_dir_name )
          then delete_temp_results (name ^/ entry) ;
          cleandir dir (* next entry *)
      | None ->
          Unix.closedir dir
    in
    match Unix.opendir name with
    | dir ->
        cleandir dir
    | exception Unix.Unix_error (Unix.ENOTDIR, _, _) ->
        if should_delete_file name then Unix.unlink name ;
        ()
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        ()
  in
  delete_temp_results Config.results_dir
