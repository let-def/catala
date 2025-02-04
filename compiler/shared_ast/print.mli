(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** Printing functions for the default calculus AST *)

open Catala_utils
open Definitions

(** {1 Common syntax highlighting helpers}*)

val base_type : Format.formatter -> string -> unit
val keyword : Format.formatter -> string -> unit

val punctuation : Format.formatter -> string -> unit
(** The argument is assumed to be 1-column wide (but can be a multi-char utf8
    character) *)

val op_style : Format.formatter -> string -> unit
val lit_style : Format.formatter -> string -> unit

(** {1 Some basic stringifiers} *)

val operator_to_string : 'a operator -> string
(** Prints the operator symbols with kind suffixes, as expected by the OCaml
    backend (e.g. "+^", "+$", etc.) *)

(** {1 Formatters} *)

val uid_list : Format.formatter -> Uid.MarkedString.info list -> unit
val enum_constructor : Format.formatter -> EnumConstructor.t -> unit
val tlit : Format.formatter -> typ_lit -> unit
val location : Format.formatter -> 'a glocation -> unit
val typ : decl_ctx -> Format.formatter -> typ -> unit
val lit : Format.formatter -> lit -> unit
val operator : ?debug:bool -> Format.formatter -> 'a operator -> unit
val log_entry : Format.formatter -> log_entry -> unit
val except : Format.formatter -> except -> unit
val var : Format.formatter -> 'e Var.t -> unit
val var_debug : Format.formatter -> 'e Var.t -> unit

val expr :
  ?hide_function_body:bool ->
  ?debug:bool ->
  unit ->
  Format.formatter ->
  ('a, 'm) gexpr ->
  unit
(** Same as [expr], but with a debug flag that defaults to [!Cli.debug_flag]. If
    [~hide_function_body:true], prints "<function>" for [EAbs] nodes *)

(** {1 Debugging versions that don't require a context} *)

val typ_debug : Format.formatter -> typ -> unit

val scope :
  ?debug:bool ->
  decl_ctx ->
  Format.formatter ->
  ScopeName.t * ('a, 'm) gexpr scope_body ->
  unit

val program : ?debug:bool -> Format.formatter -> ('a, 'm) gexpr program -> unit
