(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria,
   contributors: Denis Merigoux <denis.merigoux@inria.fr>, Emile Rolley
   <emile.rolley@tuta.io>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils

(** Associates a file extension with its corresponding {!type: Cli.backend_lang}
    string representation. *)
let extensions = [".catala_fr", "fr"; ".catala_en", "en"; ".catala_pl", "pl"]

let get_scope_uid
    (options : Cli.options)
    (backend : Plugin.t Cli.backend_option)
    (ctxt : Desugared.Name_resolution.context) =
  match options.ex_scope, backend with
  | None, `Interpret ->
    Errors.raise_error "No scope was provided for execution."
  | None, _ ->
    let _, scope =
      try
        Shared_ast.IdentName.Map.filter_map
          (fun _ -> function
            | Desugared.Name_resolution.TScope (uid, _) -> Some uid
            | _ -> None)
          ctxt.typedefs
        |> Shared_ast.IdentName.Map.choose
      with Not_found ->
        Errors.raise_error "There isn't any scope inside the program."
    in
    scope
  | Some name, _ -> (
    match Shared_ast.IdentName.Map.find_opt name ctxt.typedefs with
    | Some (Desugared.Name_resolution.TScope (uid, _)) -> uid
    | _ ->
      Errors.raise_error "There is no scope %a inside the program."
        (Cli.format_with_style [ANSITerminal.yellow])
        ("\"" ^ name ^ "\""))

let get_variable_uid
    (options : Cli.options)
    (backend : Plugin.t Cli.backend_option)
    (ctxt : Desugared.Name_resolution.context)
    (scope_uid : Shared_ast.ScopeName.t) =
  match options.ex_variable, backend with
  | None, `Exceptions ->
    Errors.raise_error
      "Please specify a variable with the -v option to print its exception \
       tree."
  | None, _ -> None
  | Some name, _ -> (
    (* Sometimes the variable selected is of the form [a.b]*)
    let first_part, second_part =
      match
        Re.(
          exec_opt
            (compile
            @@ whole_string
            @@ seq [group (rep1 (compl [char '.'])); char '.'; group (rep1 any)]
            )
            name)
      with
      | None -> name, None
      | Some groups -> Re.Group.get groups 1, Some (Re.Group.get groups 2)
    in
    match
      Shared_ast.IdentName.Map.find_opt first_part
        (Shared_ast.ScopeName.Map.find scope_uid ctxt.scopes).var_idmap
    with
    | None ->
      Errors.raise_error "Variable %a not found inside scope %a"
        (Cli.format_with_style [ANSITerminal.yellow])
        ("\"" ^ name ^ "\"")
        (Cli.format_with_style [ANSITerminal.yellow])
        (Format.asprintf "\"%a\"" Shared_ast.ScopeName.format_t scope_uid)
    | Some
        (Desugared.Name_resolution.SubScope (subscope_var_name, subscope_name))
      -> (
      match second_part with
      | None ->
        Errors.raise_error
          "Subscope %a of scope %a cannot be selected by itself, please add \
           \".<var>\" where <var> is a subscope variable."
          (Cli.format_with_style [ANSITerminal.yellow])
          (Format.asprintf "\"%a\"" Shared_ast.SubScopeName.format_t
             subscope_var_name)
          (Cli.format_with_style [ANSITerminal.yellow])
          (Format.asprintf "\"%a\"" Shared_ast.ScopeName.format_t scope_uid)
      | Some second_part -> (
        match
          Shared_ast.IdentName.Map.find_opt second_part
            (Shared_ast.ScopeName.Map.find subscope_name ctxt.scopes).var_idmap
        with
        | Some (Desugared.Name_resolution.ScopeVar v) ->
          Some
            (Desugared.Ast.ScopeDef.SubScopeVar
               (subscope_var_name, v, Pos.no_pos))
        | _ ->
          Errors.raise_error
            "Var %a of subscope %a in scope %a does not exist, please check \
             your command line arguments."
            (Cli.format_with_style [ANSITerminal.yellow])
            ("\"" ^ second_part ^ "\"")
            (Cli.format_with_style [ANSITerminal.yellow])
            (Format.asprintf "\"%a\"" Shared_ast.SubScopeName.format_t
               subscope_var_name)
            (Cli.format_with_style [ANSITerminal.yellow])
            (Format.asprintf "\"%a\"" Shared_ast.ScopeName.format_t scope_uid)))
    | Some (Desugared.Name_resolution.ScopeVar v) ->
      Some
        (Desugared.Ast.ScopeDef.Var
           ( v,
             Option.map
               (fun second_part ->
                 let var_sig = Shared_ast.ScopeVar.Map.find v ctxt.var_typs in
                 match
                   Shared_ast.IdentName.Map.find_opt second_part
                     var_sig.var_sig_states_idmap
                 with
                 | Some state -> state
                 | None ->
                   Errors.raise_error
                     "State %a is not found for variable %a of scope %a"
                     (Cli.format_with_style [ANSITerminal.yellow])
                     ("\"" ^ second_part ^ "\"")
                     (Cli.format_with_style [ANSITerminal.yellow])
                     ("\"" ^ first_part ^ "\"")
                     (Cli.format_with_style [ANSITerminal.yellow])
                     (Format.asprintf "\"%a\"" Shared_ast.ScopeName.format_t
                        scope_uid))
               second_part )))

(** Entry function for the executable. Returns a negative number in case of
    error. Usage: [driver source_file options]*)
let driver source_file (options : Cli.options) : int =
  try
    List.iter
      (fun d ->
        match Sys.is_directory d with
        | true -> Plugin.load_dir d
        | false -> ()
        | exception Sys_error _ -> ())
      options.plugins_dirs;
    Cli.set_option_globals options;
    if options.debug then Printexc.record_backtrace true;
    Cli.debug_print "Reading files...";
    let filename = ref "" in
    (match source_file with
    | Pos.FileName f -> filename := f
    | Contents c -> Cli.contents := c);
    let l =
      match options.language with
      | Some l -> l
      | None -> (
        (* Try to infer the language from the intput file extension. *)
        let ext = Filename.extension !filename in
        if ext = "" then
          Errors.raise_error
            "No file extension found for the file '%s'. (Try to add one or to \
             specify the -l flag)"
            !filename;
        try List.assoc ext extensions with Not_found -> ext)
    in
    let language =
      try List.assoc l Cli.languages
      with Not_found ->
        Errors.raise_error
          "The selected language (%s) is not supported by Catala" l
    in
    Cli.locale_lang := language;
    let backend = options.backend in
    let backend =
      match Cli.backend_option_of_string backend with
      | #Cli.backend_option_builtin as backend -> backend
      | `Plugin s -> (
        try `Plugin (Plugin.find s)
        with Not_found ->
          Errors.raise_error
            "The selected backend (%s) is not supported by Catala, nor was a \
             plugin by this name found under %a"
            backend
            (Format.pp_print_list
               ~pp_sep:(fun ppf () -> Format.fprintf ppf "@ or @ ")
               (fun ppf dir ->
                 Format.pp_print_string ppf
                   (try Unix.readlink dir with _ -> dir)))
            options.plugins_dirs)
    in
    let prgm =
      Surface.Parser_driver.parse_top_level_file source_file language
    in
    let prgm = Surface.Fill_positions.fill_pos_with_legislative_info prgm in
    let get_output ?ext =
      File.get_out_channel ~source_file ~output_file:options.output_file ?ext
    in
    let get_output_format ?ext =
      File.get_formatter_of_out_channel ~source_file
        ~output_file:options.output_file ?ext
    in
    (match backend with
    | `Makefile ->
      let backend_extensions_list = [".tex"] in
      let source_file =
        match source_file with
        | FileName f -> f
        | Contents _ ->
          Errors.raise_error
            "The Makefile backend does not work if the input is not a file"
      in
      let output_file, with_output = get_output ~ext:".d" () in
      Cli.debug_print "Writing list of dependencies to %s..."
        (Option.value ~default:"stdout" output_file);
      with_output
      @@ fun oc ->
      Printf.fprintf oc "%s:\\\n%s\n%s:"
        (String.concat "\\\n"
           (Option.value ~default:"stdout" output_file
           :: List.map
                (fun ext -> Filename.remove_extension source_file ^ ext)
                backend_extensions_list))
        (String.concat "\\\n" prgm.program_source_files)
        (String.concat "\\\n" prgm.program_source_files)
    | (`Latex | `Html) as backend ->
      Cli.debug_print "Weaving literate program into %s"
        (match backend with `Latex -> "LaTeX" | `Html -> "HTML");
      let output_file, with_output =
        get_output_format ()
          ~ext:(match backend with `Latex -> ".tex" | `Html -> ".html")
      in
      with_output (fun fmt ->
          let weave_output =
            match backend with
            | `Latex ->
              Literate.Latex.ast_to_latex language
                ~print_only_law:options.print_only_law
            | `Html ->
              Literate.Html.ast_to_html language
                ~print_only_law:options.print_only_law
          in
          Cli.debug_print "Writing to %s"
            (Option.value ~default:"stdout" output_file);
          if options.wrap_weaved_output then
            match backend with
            | `Latex ->
              Literate.Latex.wrap_latex prgm.Surface.Ast.program_source_files
                language fmt (fun fmt -> weave_output fmt prgm)
            | `Html ->
              Literate.Html.wrap_html prgm.Surface.Ast.program_source_files
                language fmt (fun fmt -> weave_output fmt prgm)
          else weave_output fmt prgm)
    | ( `Interpret | `Interpret_Lcalc | `Typecheck | `OCaml | `Python | `Scalc
      | `Lcalc | `Dcalc | `Scopelang | `Exceptions | `Proof | `Plugin _ ) as
      backend -> (
      Cli.debug_print "Name resolution...";
      let ctxt = Desugared.Name_resolution.form_context prgm in
      let scope_uid = get_scope_uid options backend ctxt in
      (* This uid is a Desugared identifier *)
      let variable_uid = get_variable_uid options backend ctxt scope_uid in
      Cli.debug_print "Desugaring...";
      let prgm = Desugared.From_surface.translate_program ctxt prgm in
      Cli.debug_print "Disambiguating...";
      let prgm = Desugared.Disambiguate.program prgm in
      Cli.debug_print "Linting...";
      Desugared.Linting.lint_program prgm;
      Cli.debug_print "Collecting rules...";
      let exceptions_graphs =
        Scopelang.From_desugared.build_exceptions_graph prgm
      in
      let prgm =
        Scopelang.From_desugared.translate_program prgm exceptions_graphs
      in
      match backend with
      | `Exceptions ->
        let variable_uid =
          match variable_uid with
          | Some variable_uid -> variable_uid
          | None ->
            Errors.raise_error
              "Please provide a scope variable to analyze with the -v option."
        in
        Desugared.Print.print_exceptions_graph scope_uid variable_uid
          (Desugared.Ast.ScopeDef.Map.find variable_uid exceptions_graphs)
      | `Scopelang ->
        let _output_file, with_output = get_output_format () in
        with_output
        @@ fun fmt ->
        if Option.is_some options.ex_scope then
          Format.fprintf fmt "%a\n"
            (Scopelang.Print.scope prgm.program_ctx ~debug:options.debug)
            ( scope_uid,
              Shared_ast.ScopeName.Map.find scope_uid prgm.program_scopes )
        else
          Format.fprintf fmt "%a\n"
            (Scopelang.Print.program ~debug:options.debug)
            prgm
      | ( `Interpret | `Interpret_Lcalc | `Typecheck | `OCaml | `Python | `Scalc
        | `Lcalc | `Dcalc | `Proof | `Plugin _ ) as backend -> (
        Cli.debug_print "Typechecking...";
        let type_ordering =
          Scopelang.Dependency.check_type_cycles prgm.program_ctx.ctx_structs
            prgm.program_ctx.ctx_enums
        in
        let prgm = Scopelang.Ast.type_program prgm in
        Cli.debug_print "Translating to default calculus...";
        let prgm = Dcalc.From_scopelang.translate_program prgm in
        let prgm =
          if options.optimize then begin
            Cli.debug_print "Optimizing default calculus...";
            Shared_ast.Optimizations.optimize_program prgm
          end
          else prgm
        in
        (* Cli.debug_print (Format.asprintf "Typechecking results :@\n%a"
           (Print.typ prgm.decl_ctx) typ); *)
        match backend with
        | `Typecheck ->
          Cli.debug_print "Typechecking again...";
          let _ =
            try Shared_ast.Typing.program prgm ~leave_unresolved:false
            with Errors.StructuredError (msg, details) ->
              let msg =
                "Typing error occured during re-typing on the 'default \
                 calculus'. This is a bug in the Catala compiler.\n"
                ^ msg
              in
              raise (Errors.StructuredError (msg, details))
          in
          (* That's it! *)
          Cli.result_print "Typechecking successful!"
        | `Dcalc ->
          let _output_file, with_output = get_output_format () in
          with_output
          @@ fun fmt ->
          if Option.is_some options.ex_scope then
            Format.fprintf fmt "%a\n"
              (Shared_ast.Print.scope ~debug:options.debug prgm.decl_ctx)
              ( scope_uid,
                Option.get
                  (Shared_ast.Scope.fold_left ~init:None
                     ~f:(fun acc def _ ->
                       match def with
                       | ScopeDef (name, body)
                         when Shared_ast.ScopeName.equal name scope_uid ->
                         Some body
                       | _ -> acc)
                     prgm.code_items) )
          else
            let prgrm_dcalc_expr =
              Shared_ast.Expr.unbox (Shared_ast.Program.to_expr prgm scope_uid)
            in
            Format.fprintf fmt "%a\n"
              (Shared_ast.Print.expr ~debug:options.debug ())
              prgrm_dcalc_expr
        | ( `Interpret | `OCaml | `Python | `Scalc | `Lcalc | `Proof | `Plugin _
          | `Interpret_Lcalc ) as backend -> (
          Cli.debug_print "Typechecking again...";
          let prgm =
            try Shared_ast.Typing.program ~leave_unresolved:false prgm
            with Errors.StructuredError (msg, details) ->
              let msg =
                "Typing error occured during re-typing on the 'default \
                 calculus'. This is a bug in the Catala compiler.\n"
                ^ msg
              in
              raise (Errors.StructuredError (msg, details))
          in
          if !Cli.check_invariants_flag then (
            Cli.debug_format "Checking invariants...";
            let result = Dcalc.Invariants.check_all_invariants prgm in
            if not result then
              raise
                (Errors.raise_internal_error "Some Dcalc invariants are invalid"));
          match backend with
          | `Proof ->
            let vcs =
              Verification.Conditions.generate_verification_conditions prgm
                (match options.ex_scope with
                | None -> None
                | Some _ -> Some scope_uid)
            in

            Verification.Solver.solve_vc prgm.decl_ctx vcs
          | `Interpret ->
            Cli.debug_print "Starting interpretation (dcalc)...";
            let results =
              Shared_ast.Interpreter.interpret_program_dcalc prgm scope_uid
            in
            let results =
              List.sort
                (fun ((v1, _), _) ((v2, _), _) -> String.compare v1 v2)
                results
            in
            Cli.debug_print "End of interpretation";
            Cli.result_print "Computation successful!%s"
              (if List.length results > 0 then " Results:" else "");
            List.iter
              (fun ((var, _), result) ->
                Cli.result_format "@[<hov 2>%s@ =@ %a@]" var
                  (Shared_ast.Print.expr ~debug:options.debug ())
                  result)
              results
          | `Plugin (Plugin.Dcalc p) ->
            let output_file, _ = get_output_format ~ext:p.Plugin.extension () in
            Cli.debug_print "Compiling program through backend \"%s\"..."
              p.Plugin.name;
            p.Plugin.apply ~source_file ~output_file
              ~scope:
                (match options.ex_scope with
                | None -> None
                | Some _ -> Some scope_uid)
              (Shared_ast.Program.untype prgm)
              type_ordering
          | (`OCaml | `Interpret_Lcalc | `Python | `Lcalc | `Scalc | `Plugin _)
            as backend -> (
            Cli.debug_print "Compiling program into lambda calculus...";
            let prgm =
              if options.trace && options.avoid_exceptions then
                Errors.raise_error
                  "Option --avoid_exceptions is not compatible with option \
                   --trace";
              if options.avoid_exceptions then
                Shared_ast.Program.untype
                @@ Lcalc.Compile_without_exceptions.translate_program prgm
              else
                Shared_ast.Program.untype
                @@ Lcalc.Compile_with_exceptions.translate_program prgm
            in
            let prgm =
              if options.optimize then begin
                Cli.debug_print "Optimizing lambda calculus...";
                Shared_ast.Optimizations.optimize_program prgm
              end
              else Shared_ast.Program.untype prgm
            in
            let prgm =
              if options.closure_conversion then (
                if not options.avoid_exceptions then
                  Errors.raise_error
                    "Option --avoid_exceptions must be enabled for \
                     --closure_conversion";
                Cli.debug_print "Performing closure conversion...";
                let prgm = Lcalc.Closure_conversion.closure_conversion prgm in
                let prgm = Bindlib.unbox prgm in
                let prgm =
                  if options.optimize then (
                    Cli.debug_print "Optimizing lambda calculus...";
                    Shared_ast.Optimizations.optimize_program prgm)
                  else prgm
                in
                Cli.debug_print "Retyping lambda calculus...";
                let prgm =
                  Shared_ast.Program.untype
                    (Shared_ast.Typing.program ~leave_unresolved:true prgm)
                in
                prgm)
              else prgm
            in
            match backend with
            | `Lcalc ->
              let _output_file, with_output = get_output_format () in
              with_output
              @@ fun fmt ->
              if Option.is_some options.ex_scope then
                Format.fprintf fmt "%a\n"
                  (Shared_ast.Print.scope ~debug:options.debug prgm.decl_ctx)
                  (scope_uid, Shared_ast.Program.get_scope_body prgm scope_uid)
              else
                Format.fprintf fmt "%a\n"
                  (Shared_ast.Print.program ~debug:options.debug)
                  prgm
            | `Interpret_Lcalc ->
              Cli.debug_print "Starting interpretation (lcalc)...";
              let results =
                Shared_ast.Interpreter.interpret_program_lcalc prgm scope_uid
              in
              let results =
                List.sort
                  (fun ((v1, _), _) ((v2, _), _) -> String.compare v1 v2)
                  results
              in
              Cli.debug_print "End of interpretation";
              Cli.result_print "Computation successful!%s"
                (if List.length results > 0 then " Results:" else "");
              List.iter
                (fun ((var, _), result) ->
                  Cli.result_format "@[<hov 2>%s@ =@ %a@]" var
                    (Shared_ast.Print.expr ~debug:options.debug ())
                    result)
                results
            | (`OCaml | `Python | `Scalc | `Plugin _) as backend -> (
              match backend with
              | `OCaml ->
                let output_file, with_output =
                  get_output_format ~ext:".ml" ()
                in
                with_output
                @@ fun fmt ->
                Cli.debug_print "Compiling program into OCaml...";
                Cli.debug_print "Writing to %s..."
                  (Option.value ~default:"stdout" output_file);
                Lcalc.To_ocaml.format_program fmt prgm type_ordering
              | `Plugin (Plugin.Dcalc _) -> assert false
              | `Plugin (Plugin.Lcalc p) ->
                let output_file, _ =
                  get_output_format ~ext:p.Plugin.extension ()
                in
                Cli.debug_print "Compiling program through backend \"%s\"..."
                  p.Plugin.name;
                p.Plugin.apply ~source_file ~output_file
                  ~scope:
                    (match options.ex_scope with
                    | None -> None
                    | Some _ -> Some scope_uid)
                  prgm type_ordering
              | (`Python | `Scalc | `Plugin (Plugin.Scalc _)) as backend -> (
                let prgm = Scalc.From_lcalc.translate_program prgm in
                match backend with
                | `Scalc ->
                  let _output_file, with_output = get_output_format () in
                  with_output
                  @@ fun fmt ->
                  if Option.is_some options.ex_scope then
                    Format.fprintf fmt "%a\n"
                      (Scalc.Print.format_item ~debug:options.debug
                         prgm.decl_ctx)
                      (List.find
                         (function
                           | Scalc.Ast.SScope { scope_body_name; _ } ->
                             scope_body_name = scope_uid
                           | _ -> false)
                         prgm.code_items)
                  else Scalc.Print.format_program prgm.decl_ctx fmt prgm
                | `Python ->
                  let output_file, with_output =
                    get_output_format ~ext:".py" ()
                  in
                  Cli.debug_print "Compiling program into Python...";
                  Cli.debug_print "Writing to %s..."
                    (Option.value ~default:"stdout" output_file);
                  with_output
                  @@ fun fmt ->
                  Scalc.To_python.format_program fmt prgm type_ordering
                | `Plugin (Plugin.Dcalc _ | Plugin.Lcalc _) -> assert false
                | `Plugin (Plugin.Scalc p) ->
                  let output_file, _ = get_output ~ext:p.Plugin.extension () in
                  Cli.debug_print "Compiling program through backend \"%s\"..."
                    p.Plugin.name;
                  Cli.debug_print "Writing to %s..."
                    (Option.value ~default:"stdout" output_file);
                  p.Plugin.apply ~source_file ~output_file
                    ~scope:
                      (match options.ex_scope with
                      | None -> None
                      | Some _ -> Some scope_uid)
                    prgm type_ordering)))))));
    0
  with
  | Errors.StructuredError (msg, pos) ->
    let bt = Printexc.get_raw_backtrace () in
    Errors.print_structured_error msg pos;
    if Printexc.backtrace_status () then Printexc.print_raw_backtrace stderr bt;
    -1
  | Sys_error msg ->
    let bt = Printexc.get_raw_backtrace () in
    Cli.error_print "System error: %s" msg;
    if Printexc.backtrace_status () then Printexc.print_raw_backtrace stderr bt;
    -1

let main () =
  if
    Array.length Sys.argv >= 2
    && String.lowercase_ascii Sys.argv.(1) = "pygmentize"
  then Literate.Pygmentize.exec ();
  let return_code =
    Cmdliner.Cmd.eval'
      (Cmdliner.Cmd.v Cli.info (Cli.catala_t (fun f -> driver (FileName f))))
  in
  exit return_code

(* Export module PluginAPI, hide parent module Plugin *)
module Plugin = Plugin.PluginAPI
