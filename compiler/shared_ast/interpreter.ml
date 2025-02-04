(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>, Emile Rolley
   <emile.rolley@tuta.io>, Alain Delaët <alain.delaet--tixeuil@inria.Fr>, Louis
   Gesbert <louis.gesbert@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** Reference interpreter for the default calculus *)

open Catala_utils
open Definitions
open Op
module Runtime = Runtime_ocaml.Runtime

(** {1 Helpers} *)

let is_empty_error : type a. (a, 'm) gexpr -> bool =
 fun e -> match Mark.remove e with EEmptyError -> true | _ -> false

(** [e' = propagate_empty_error e f] return [EEmptyError] if [e] is
    [EEmptyError], else it apply [f] on not-empty term [e]. *)
let propagate_empty_error :
    type a. (a, 'm) gexpr -> ((a, 'm) gexpr -> (a, 'm) gexpr) -> (a, 'm) gexpr =
 fun e f -> match e with (EEmptyError, _) as e -> e | e -> f e

(** [e' = propagate_empty_error_list elist f] return [EEmptyError] if one lement
    of [es] is [EEmptyError], else it apply [f] on not-empty term list [elist]. *)
let propagate_empty_error_list elist f =
  let rec aux acc = function
    | [] -> f (List.rev acc)
    | e :: r -> propagate_empty_error e (fun e -> aux (e :: acc) r)
  in
  aux [] elist

let log_indent = ref 0

(* TODO: we should provide a generic way to print logs, that work across the
   different backends: python, ocaml, javascript, and interpreter *)

(** {1 Evaluation} *)
let print_log entry infos pos e =
  if !Cli.trace_flag then
    match entry with
    | VarDef _ ->
      (* TODO: this usage of Format is broken, Formatting requires that all is
         formatted in one pass, without going through intermediate "%s" *)
      Cli.log_format "%*s%a %a: %s" (!log_indent * 2) "" Print.log_entry entry
        Print.uid_list infos
        (let expr_str =
           Format.asprintf "%a" (Print.expr ~hide_function_body:true ()) e
         in
         let expr_str =
           Re.Pcre.substitute ~rex:(Re.Pcre.regexp "\n\\s*")
             ~subst:(fun _ -> " ")
             expr_str
         in
         Cli.with_style [ANSITerminal.green] "%s" expr_str)
    | PosRecordIfTrueBool -> (
      match pos <> Pos.no_pos, Mark.remove e with
      | true, ELit (LBool true) ->
        Cli.log_format "%*s%a%s:\n%s" (!log_indent * 2) "" Print.log_entry entry
          (Cli.with_style [ANSITerminal.green] "Definition applied")
          (Cli.add_prefix_to_each_line (Pos.retrieve_loc_text pos) (fun _ ->
               Format.asprintf "%*s" (!log_indent * 2) ""))
      | _ -> ())
    | BeginCall ->
      Cli.log_format "%*s%a %a" (!log_indent * 2) "" Print.log_entry entry
        Print.uid_list infos;
      log_indent := !log_indent + 1
    | EndCall ->
      log_indent := !log_indent - 1;
      Cli.log_format "%*s%a %a" (!log_indent * 2) "" Print.log_entry entry
        Print.uid_list infos

exception CatalaException of except

(* Todo: this should be handled early when resolving overloads. Here we have
   proper structural equality, but the OCaml backend for example uses the
   builtin equality function instead of this. *)
let handle_eq evaluate_operator pos e1 e2 =
  let open Runtime.Oper in
  match e1, e2 with
  | ELit LUnit, ELit LUnit -> true
  | ELit (LBool b1), ELit (LBool b2) -> not (o_xor b1 b2)
  | ELit (LInt x1), ELit (LInt x2) -> o_eq_int_int x1 x2
  | ELit (LRat x1), ELit (LRat x2) -> o_eq_rat_rat x1 x2
  | ELit (LMoney x1), ELit (LMoney x2) -> o_eq_mon_mon x1 x2
  | ELit (LDuration x1), ELit (LDuration x2) -> o_eq_dur_dur x1 x2
  | ELit (LDate x1), ELit (LDate x2) -> o_eq_dat_dat x1 x2
  | EArray es1, EArray es2 -> (
    try
      List.for_all2
        (fun e1 e2 ->
          match Mark.remove (evaluate_operator Eq pos [e1; e2]) with
          | ELit (LBool b) -> b
          | _ -> assert false
          (* should not happen *))
        es1 es2
    with Invalid_argument _ -> false)
  | EStruct { fields = es1; name = s1 }, EStruct { fields = es2; name = s2 } ->
    StructName.equal s1 s2
    && StructField.Map.equal
         (fun e1 e2 ->
           match Mark.remove (evaluate_operator Eq pos [e1; e2]) with
           | ELit (LBool b) -> b
           | _ -> assert false
           (* should not happen *))
         es1 es2
  | ( EInj { e = e1; cons = i1; name = en1 },
      EInj { e = e2; cons = i2; name = en2 } ) -> (
    try
      EnumName.equal en1 en2
      && EnumConstructor.equal i1 i2
      &&
      match Mark.remove (evaluate_operator Eq pos [e1; e2]) with
      | ELit (LBool b) -> b
      | _ -> assert false
      (* should not happen *)
    with Invalid_argument _ -> false)
  | _, _ -> false (* comparing anything else return false *)

(* Call-by-value: the arguments are expected to be already evaluated here *)
let rec evaluate_operator
    evaluate_expr
    (op : < overloaded : no ; .. > operator)
    m
    args =
  let pos = Expr.mark_pos m in
  let protect f x y =
    let get_binop_args_pos = function
      | (arg0 :: arg1 :: _ : ('t, 'm) gexpr list) ->
        [None, Expr.pos arg0; None, Expr.pos arg1]
      | _ -> assert false
    in
    try f x y with
    | Division_by_zero ->
      Errors.raise_multispanned_error
        [
          Some "The division operator:", pos;
          Some "The null denominator:", Expr.pos (List.nth args 1);
        ]
        "division by zero at runtime"
    | Runtime.UncomparableDurations ->
      Errors.raise_multispanned_error (get_binop_args_pos args)
        "Cannot compare together durations that cannot be converted to a \
         precise number of days"
  in
  let err () =
    Errors.raise_multispanned_error
      ([Some "Operator:", pos]
      @ List.mapi
          (fun i arg ->
            ( Some
                (Format.asprintf "Argument n°%d, value %a" (i + 1)
                   (Print.expr ()) arg),
              Expr.pos arg ))
          args)
      "Operator applied to the wrong arguments\n\
       (should not happen if the term was well-typed)"
  in
  propagate_empty_error_list args
  @@ fun args ->
  let open Runtime.Oper in
  Mark.add m
  @@
  match op, args with
  | Length, [(EArray es, _)] ->
    ELit (LInt (Runtime.integer_of_int (List.length es)))
  | Log (entry, infos), [e'] ->
    print_log entry infos pos e';
    Mark.remove e'
  | Eq, [(e1, _); (e2, _)] ->
    ELit (LBool (handle_eq (evaluate_operator evaluate_expr) m e1 e2))
  | Map, [f; (EArray es, _)] ->
    EArray
      (List.map
         (fun e' -> evaluate_expr (Mark.copy e' (EApp { f; args = [e'] })))
         es)
  | Reduce, [_; default; (EArray [], _)] -> Mark.remove default
  | Reduce, [f; _; (EArray (x0 :: xn), _)] ->
    Mark.remove
      (List.fold_left
         (fun acc x ->
           evaluate_expr (Mark.copy f (EApp { f; args = [acc; x] })))
         x0 xn)
  | Concat, [(EArray es1, _); (EArray es2, _)] -> EArray (es1 @ es2)
  | Filter, [f; (EArray es, _)] ->
    EArray
      (List.filter
         (fun e' ->
           match evaluate_expr (Mark.copy e' (EApp { f; args = [e'] })) with
           | ELit (LBool b), _ -> b
           | _ ->
             Errors.raise_spanned_error
               (Expr.pos (List.nth args 0))
               "This predicate evaluated to something else than a boolean \
                (should not happen if the term was well-typed)")
         es)
  | Fold, [f; init; (EArray es, _)] ->
    Mark.remove
      (List.fold_left
         (fun acc e' ->
           evaluate_expr (Mark.copy e' (EApp { f; args = [acc; e'] })))
         init es)
  | (Length | Log _ | Eq | Map | Concat | Filter | Fold | Reduce), _ -> err ()
  | Not, [(ELit (LBool b), _)] -> ELit (LBool (o_not b))
  | GetDay, [(ELit (LDate d), _)] -> ELit (LInt (o_getDay d))
  | GetMonth, [(ELit (LDate d), _)] -> ELit (LInt (o_getMonth d))
  | GetYear, [(ELit (LDate d), _)] -> ELit (LInt (o_getYear d))
  | FirstDayOfMonth, [(ELit (LDate d), _)] -> ELit (LDate (o_firstDayOfMonth d))
  | LastDayOfMonth, [(ELit (LDate d), _)] -> ELit (LDate (o_lastDayOfMonth d))
  | And, [(ELit (LBool b1), _); (ELit (LBool b2), _)] ->
    ELit (LBool (o_and b1 b2))
  | Or, [(ELit (LBool b1), _); (ELit (LBool b2), _)] ->
    ELit (LBool (o_or b1 b2))
  | Xor, [(ELit (LBool b1), _); (ELit (LBool b2), _)] ->
    ELit (LBool (o_xor b1 b2))
  | ( ( Not | GetDay | GetMonth | GetYear | FirstDayOfMonth | LastDayOfMonth
      | And | Or | Xor ),
      _ ) ->
    err ()
  | Minus_int, [(ELit (LInt x), _)] -> ELit (LInt (o_minus_int x))
  | Minus_rat, [(ELit (LRat x), _)] -> ELit (LRat (o_minus_rat x))
  | Minus_mon, [(ELit (LMoney x), _)] -> ELit (LMoney (o_minus_mon x))
  | Minus_dur, [(ELit (LDuration x), _)] -> ELit (LDuration (o_minus_dur x))
  | ToRat_int, [(ELit (LInt i), _)] -> ELit (LRat (o_torat_int i))
  | ToRat_mon, [(ELit (LMoney i), _)] -> ELit (LRat (o_torat_mon i))
  | ToMoney_rat, [(ELit (LRat i), _)] -> ELit (LMoney (o_tomoney_rat i))
  | Round_mon, [(ELit (LMoney m), _)] -> ELit (LMoney (o_round_mon m))
  | Round_rat, [(ELit (LRat m), _)] -> ELit (LRat (o_round_rat m))
  | Add_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LInt (o_add_int_int x y))
  | Add_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LRat (o_add_rat_rat x y))
  | Add_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LMoney (o_add_mon_mon x y))
  | Add_dat_dur r, [(ELit (LDate x), _); (ELit (LDuration y), _)] ->
    ELit (LDate (o_add_dat_dur r x y))
  | Add_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LDuration (o_add_dur_dur x y))
  | Sub_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LInt (o_sub_int_int x y))
  | Sub_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LRat (o_sub_rat_rat x y))
  | Sub_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LMoney (o_sub_mon_mon x y))
  | Sub_dat_dat, [(ELit (LDate x), _); (ELit (LDate y), _)] ->
    ELit (LDuration (o_sub_dat_dat x y))
  | Sub_dat_dur, [(ELit (LDate x), _); (ELit (LDuration y), _)] ->
    ELit (LDate (o_sub_dat_dur x y))
  | Sub_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LDuration (o_sub_dur_dur x y))
  | Mult_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LInt (o_mult_int_int x y))
  | Mult_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LRat (o_mult_rat_rat x y))
  | Mult_mon_rat, [(ELit (LMoney x), _); (ELit (LRat y), _)] ->
    ELit (LMoney (o_mult_mon_rat x y))
  | Mult_dur_int, [(ELit (LDuration x), _); (ELit (LInt y), _)] ->
    ELit (LDuration (o_mult_dur_int x y))
  | Div_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LRat (protect o_div_int_int x y))
  | Div_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LRat (protect o_div_rat_rat x y))
  | Div_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LRat (protect o_div_mon_mon x y))
  | Div_mon_rat, [(ELit (LMoney x), _); (ELit (LRat y), _)] ->
    ELit (LMoney (protect o_div_mon_rat x y))
  | Div_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LRat (protect o_div_dur_dur x y))
  | Lt_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LBool (o_lt_int_int x y))
  | Lt_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LBool (o_lt_rat_rat x y))
  | Lt_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LBool (o_lt_mon_mon x y))
  | Lt_dat_dat, [(ELit (LDate x), _); (ELit (LDate y), _)] ->
    ELit (LBool (o_lt_dat_dat x y))
  | Lt_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LBool (protect o_lt_dur_dur x y))
  | Lte_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LBool (o_lte_int_int x y))
  | Lte_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LBool (o_lte_rat_rat x y))
  | Lte_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LBool (o_lte_mon_mon x y))
  | Lte_dat_dat, [(ELit (LDate x), _); (ELit (LDate y), _)] ->
    ELit (LBool (o_lte_dat_dat x y))
  | Lte_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LBool (protect o_lte_dur_dur x y))
  | Gt_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LBool (o_gt_int_int x y))
  | Gt_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LBool (o_gt_rat_rat x y))
  | Gt_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LBool (o_gt_mon_mon x y))
  | Gt_dat_dat, [(ELit (LDate x), _); (ELit (LDate y), _)] ->
    ELit (LBool (o_gt_dat_dat x y))
  | Gt_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LBool (protect o_gt_dur_dur x y))
  | Gte_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LBool (o_gte_int_int x y))
  | Gte_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LBool (o_gte_rat_rat x y))
  | Gte_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LBool (o_gte_mon_mon x y))
  | Gte_dat_dat, [(ELit (LDate x), _); (ELit (LDate y), _)] ->
    ELit (LBool (o_gte_dat_dat x y))
  | Gte_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LBool (protect o_gte_dur_dur x y))
  | Eq_int_int, [(ELit (LInt x), _); (ELit (LInt y), _)] ->
    ELit (LBool (o_eq_int_int x y))
  | Eq_rat_rat, [(ELit (LRat x), _); (ELit (LRat y), _)] ->
    ELit (LBool (o_eq_rat_rat x y))
  | Eq_mon_mon, [(ELit (LMoney x), _); (ELit (LMoney y), _)] ->
    ELit (LBool (o_eq_mon_mon x y))
  | Eq_dat_dat, [(ELit (LDate x), _); (ELit (LDate y), _)] ->
    ELit (LBool (o_eq_dat_dat x y))
  | Eq_dur_dur, [(ELit (LDuration x), _); (ELit (LDuration y), _)] ->
    ELit (LBool (protect o_eq_dur_dur x y))
  | HandleDefaultOpt, [(EArray exps, _); justification; conclusion] -> (
    let valid_exceptions =
      ListLabels.filter exps ~f:(function
        | EInj { name; cons; _ }, _ when EnumName.equal name Expr.option_enum ->
          EnumConstructor.equal cons Expr.some_constr
        | _ -> err ())
    in

    match valid_exceptions with
    | [] -> (
      match
        Mark.remove (evaluate_expr (Expr.unthunk_term_nobox justification m))
      with
      | EInj { name; cons; e = ELit (LBool true), _ }
        when EnumName.equal name Expr.option_enum
             && EnumConstructor.equal cons Expr.some_constr ->
        Mark.remove (evaluate_expr (Expr.unthunk_term_nobox conclusion m))
      | EInj { name; cons; e = (ELit (LBool false), _) as e }
        when EnumName.equal name Expr.option_enum
             && EnumConstructor.equal cons Expr.some_constr ->
        EInj
          {
            name = Expr.option_enum;
            cons = Expr.none_constr;
            e = Mark.copy e (ELit LUnit);
          }
      | EInj { name; cons; e }
        when EnumName.equal name Expr.option_enum
             && EnumConstructor.equal cons Expr.none_constr ->
        EInj
          {
            name = Expr.option_enum;
            cons = Expr.none_constr;
            e = Mark.copy e (ELit LUnit);
          }
      | _ -> err ())
    | [((EInj { cons; name; _ } as e), _)]
      when EnumName.equal name Expr.option_enum
           && EnumConstructor.equal cons Expr.some_constr ->
      e
    | [_] -> err ()
    | _ -> raise (CatalaException ConflictError))
  | ( ( Minus_int | Minus_rat | Minus_mon | Minus_dur | ToRat_int | ToRat_mon
      | ToMoney_rat | Round_rat | Round_mon | Add_int_int | Add_rat_rat
      | Add_mon_mon | Add_dat_dur _ | Add_dur_dur | Sub_int_int | Sub_rat_rat
      | Sub_mon_mon | Sub_dat_dat | Sub_dat_dur | Sub_dur_dur | Mult_int_int
      | Mult_rat_rat | Mult_mon_rat | Mult_dur_int | Div_int_int | Div_rat_rat
      | Div_mon_mon | Div_mon_rat | Div_dur_dur | Lt_int_int | Lt_rat_rat
      | Lt_mon_mon | Lt_dat_dat | Lt_dur_dur | Lte_int_int | Lte_rat_rat
      | Lte_mon_mon | Lte_dat_dat | Lte_dur_dur | Gt_int_int | Gt_rat_rat
      | Gt_mon_mon | Gt_dat_dat | Gt_dur_dur | Gte_int_int | Gte_rat_rat
      | Gte_mon_mon | Gte_dat_dat | Gte_dur_dur | Eq_int_int | Eq_rat_rat
      | Eq_mon_mon | Eq_dat_dat | Eq_dur_dur | HandleDefault | HandleDefaultOpt
        ),
      _ ) ->
    err ()

let rec evaluate_expr :
    type a b.
    decl_ctx -> ((a, b) dcalc_lcalc, 'm) gexpr -> ((a, b) dcalc_lcalc, 'm) gexpr
    =
 fun ctx e ->
  let m = Mark.get e in
  let pos = Expr.mark_pos m in
  match Mark.remove e with
  | EVar _ ->
    Errors.raise_spanned_error pos
      "free variable found at evaluation (should not happen if term was \
       well-typed)"
  | EApp { f = e1; args } -> (
    let e1 = evaluate_expr ctx e1 in
    let args = List.map (evaluate_expr ctx) args in
    propagate_empty_error e1
    @@ fun e1 ->
    match Mark.remove e1 with
    | EAbs { binder; _ } ->
      if Bindlib.mbinder_arity binder = List.length args then
        evaluate_expr ctx
          (Bindlib.msubst binder (Array.of_list (List.map Mark.remove args)))
      else
        Errors.raise_spanned_error pos
          "wrong function call, expected %d arguments, got %d"
          (Bindlib.mbinder_arity binder)
          (List.length args)
    | EOp { op; _ } -> evaluate_operator (evaluate_expr ctx) op m args
    | _ ->
      Errors.raise_spanned_error pos
        "function has not been reduced to a lambda at evaluation (should not \
         happen if the term was well-typed")
  | (EAbs _ | ELit _ | EOp _) as e -> Mark.add m e (* these are values *)
  | EStruct { fields = es; name } ->
    let fields, es = List.split (StructField.Map.bindings es) in
    let es = List.map (evaluate_expr ctx) es in
    propagate_empty_error_list es
    @@ fun es ->
    Mark.add m
      (EStruct
         {
           fields =
             StructField.Map.of_seq
               (Seq.zip (List.to_seq fields) (List.to_seq es));
           name;
         })
  | EStructAccess { e; name = s; field } -> (
    propagate_empty_error (evaluate_expr ctx e)
    @@ fun e ->
    match Mark.remove e with
    | EStruct { fields = es; name } -> (
      if not (StructName.equal s name) then
        Errors.raise_multispanned_error
          [None, pos; None, Expr.pos e]
          "Error during struct access: not the same structs (should not happen \
           if the term was well-typed)";
      match StructField.Map.find_opt field es with
      | Some e' -> e'
      | None ->
        Errors.raise_spanned_error (Expr.pos e)
          "Invalid field access %a in struct %a (should not happen if the term \
           was well-typed)"
          StructField.format_t field StructName.format_t s)
    | _ ->
      Errors.raise_spanned_error (Expr.pos e)
        "The expression %a should be a struct %a but is not (should not happen \
         if the term was well-typed)"
        (Print.expr ()) e StructName.format_t s)
  | ETuple es -> Mark.add m (ETuple (List.map (evaluate_expr ctx) es))
  | ETupleAccess { e = e1; index; size } -> (
    match evaluate_expr ctx e1 with
    | ETuple es, _ when List.length es = size -> List.nth es index
    | e ->
      Errors.raise_spanned_error (Expr.pos e)
        "The expression %a was expected to be a tuple of size %d (should not \
         happen if the term was well-typed)"
        (Print.expr ()) e size)
  | EInj { e; name; cons } ->
    propagate_empty_error (evaluate_expr ctx e)
    @@ fun e -> Mark.add m (EInj { e; name; cons })
  | EMatch { e; cases; name } -> (
    propagate_empty_error (evaluate_expr ctx e)
    @@ fun e ->
    match Mark.remove e with
    | EInj { e = e1; cons; name = name' } ->
      if not (EnumName.equal name name') then
        Errors.raise_multispanned_error
          [None, Expr.pos e; None, Expr.pos e1]
          "Error during match: two different enums found (should not happen if \
           the term was well-typed)";
      let es_n =
        match EnumConstructor.Map.find_opt cons cases with
        | Some es_n -> es_n
        | None ->
          Errors.raise_spanned_error (Expr.pos e)
            "sum type index error (should not happen if the term was \
             well-typed)"
      in
      let new_e = Mark.add m (EApp { f = es_n; args = [e1] }) in
      evaluate_expr ctx new_e
    | _ ->
      Errors.raise_spanned_error (Expr.pos e)
        "Expected a term having a sum type as an argument to a match (should \
         not happen if the term was well-typed")
  | EIfThenElse { cond; etrue; efalse } -> (
    propagate_empty_error (evaluate_expr ctx cond)
    @@ fun cond ->
    match Mark.remove cond with
    | ELit (LBool true) -> evaluate_expr ctx etrue
    | ELit (LBool false) -> evaluate_expr ctx efalse
    | _ ->
      Errors.raise_spanned_error (Expr.pos cond)
        "Expected a boolean literal for the result of this condition (should \
         not happen if the term was well-typed)")
  | EArray es ->
    propagate_empty_error_list (List.map (evaluate_expr ctx) es)
    @@ fun es -> Mark.add m (EArray es)
  | EAssert e' ->
    propagate_empty_error (evaluate_expr ctx e') (fun e ->
        match Mark.remove e with
        | ELit (LBool true) -> Mark.add m (ELit LUnit)
        | ELit (LBool false) -> (
          match Mark.remove (Expr.skip_wrappers e') with
          | EApp
              {
                f = EOp { op; _ }, _;
                args = [((ELit _, _) as e1); ((ELit _, _) as e2)];
              } ->
            Errors.raise_spanned_error (Expr.pos e')
              "Assertion failed: %a %a %a" (Print.expr ()) e1
              (Print.operator ~debug:!Cli.debug_flag)
              op (Print.expr ()) e2
          | _ ->
            Cli.debug_format "%a" (Print.expr ()) e';
            Errors.raise_spanned_error (Expr.mark_pos m) "Assertion failed")
        | _ ->
          Errors.raise_spanned_error (Expr.pos e')
            "Expected a boolean literal for the result of this assertion \
             (should not happen if the term was well-typed)")
  | EEmptyError -> Mark.copy e EEmptyError
  | EErrorOnEmpty e' -> (
    match evaluate_expr ctx e' with
    | EEmptyError, _ ->
      Errors.raise_spanned_error (Expr.pos e')
        "This variable evaluated to an empty term (no rule that defined it \
         applied in this situation)"
    | e -> e)
  | EDefault { excepts; just; cons } -> (
    let excepts = List.map (evaluate_expr ctx) excepts in
    let empty_count = List.length (List.filter is_empty_error excepts) in
    match List.length excepts - empty_count with
    | 0 -> (
      let just = evaluate_expr ctx just in
      match Mark.remove just with
      | EEmptyError -> Mark.add m EEmptyError
      | ELit (LBool true) -> evaluate_expr ctx cons
      | ELit (LBool false) -> Mark.copy e EEmptyError
      | _ ->
        Errors.raise_spanned_error (Expr.pos e)
          "Default justification has not been reduced to a boolean at \
           evaluation (should not happen if the term was well-typed")
    | 1 -> List.find (fun sub -> not (is_empty_error sub)) excepts
    | _ ->
      Errors.raise_multispanned_error
        (List.map
           (fun except ->
             Some "This consequence has a valid justification:", Expr.pos except)
           (List.filter (fun sub -> not (is_empty_error sub)) excepts))
        "There is a conflict between multiple valid consequences for assigning \
         the same variable.")
  | ERaise exn -> raise (CatalaException exn)
  | ECatch { body; exn; handler } -> (
    try evaluate_expr ctx body
    with CatalaException caught when Expr.equal_except caught exn ->
      evaluate_expr ctx handler)
  | _ -> .

let interpret_program_lcalc p s : (Uid.MarkedString.info * ('a, 'm) gexpr) list
    =
  let e = Expr.unbox @@ Program.to_expr p s in
  let ctx = p.decl_ctx in
  match evaluate_expr ctx e with
  | (EAbs { tys = [((TStruct s_in, _) as _targs)]; _ }, mark_e) as e -> begin
    (* At this point, the interpreter seeks to execute the scope but does not
       have a way to retrieve input values from the command line. [taus] contain
       the types of the scope arguments. For [context] arguments, we can provide
       an empty thunked term. But for [input] arguments of another type, we
       cannot provide anything so we have to fail. *)
    let taus = StructName.Map.find s_in ctx.ctx_structs in
    let application_term =
      StructField.Map.map
        (fun ty ->
          match Mark.remove ty with
          | TOption _ ->
            (Expr.einj (Expr.elit LUnit mark_e) Expr.none_constr
               Expr.option_enum mark_e
              : (_, _) boxed_gexpr)
          | _ ->
            Errors.raise_spanned_error (Mark.get ty)
              "This scope needs input arguments to be executed. But the Catala \
               built-in interpreter does not have a way to retrieve input \
               values from the command line, so it cannot execute this scope. \
               Please create another scope thatprovide the input arguments to \
               this one and execute it instead. ")
        taus
    in
    let to_interpret =
      Expr.make_app (Expr.box e)
        [Expr.estruct s_in application_term mark_e]
        (Expr.pos e)
    in
    match Mark.remove (evaluate_expr ctx (Expr.unbox to_interpret)) with
    | EStruct { fields; _ } ->
      List.map
        (fun (fld, e) -> StructField.get_info fld, e)
        (StructField.Map.bindings fields)
    | _ ->
      Errors.raise_spanned_error (Expr.pos e)
        "The interpretation of a program should always yield a struct \
         corresponding to the scope variables"
  end
  | _ ->
    Errors.raise_spanned_error (Expr.pos e)
      "The interpreter can only interpret terms starting with functions having \
       thunked arguments"

(** {1 API} *)
let interpret_program_dcalc p s : (Uid.MarkedString.info * ('a, 'm) gexpr) list
    =
  let ctx = p.decl_ctx in
  let e = Expr.unbox (Program.to_expr p s) in
  match evaluate_expr p.decl_ctx e with
  | (EAbs { tys = [((TStruct s_in, _) as _targs)]; _ }, mark_e) as e -> begin
    (* At this point, the interpreter seeks to execute the scope but does not
       have a way to retrieve input values from the command line. [taus] contain
       the types of the scope arguments. For [context] arguments, we can provide
       an empty thunked term. But for [input] arguments of another type, we
       cannot provide anything so we have to fail. *)
    let taus = StructName.Map.find s_in ctx.ctx_structs in
    let application_term =
      StructField.Map.map
        (fun ty ->
          match Mark.remove ty with
          | TArrow (ty_in, ty_out) ->
            Expr.make_abs
              (Array.of_list @@ List.map (fun _ -> Var.make "_") ty_in)
              (Bindlib.box EEmptyError, Expr.with_ty mark_e ty_out)
              ty_in (Expr.mark_pos mark_e)
          | _ ->
            Errors.raise_spanned_error (Mark.get ty)
              "This scope needs input arguments to be executed. But the Catala \
               built-in interpreter does not have a way to retrieve input \
               values from the command line, so it cannot execute this scope. \
               Please create another scope thatprovide the input arguments to \
               this one and execute it instead. ")
        taus
    in
    let to_interpret =
      Expr.make_app (Expr.box e)
        [Expr.estruct s_in application_term mark_e]
        (Expr.pos e)
    in
    match Mark.remove (evaluate_expr ctx (Expr.unbox to_interpret)) with
    | EStruct { fields; _ } ->
      List.map
        (fun (fld, e) -> StructField.get_info fld, e)
        (StructField.Map.bindings fields)
    | _ ->
      Errors.raise_spanned_error (Expr.pos e)
        "The interpretation of a program should always yield a struct \
         corresponding to the scope variables"
  end
  | _ ->
    Errors.raise_spanned_error (Expr.pos e)
      "The interpreter can only interpret terms starting with functions having \
       thunked arguments"
