(** Copyright 2023-2024, Pogorelov Ilya *)

(** SPDX-License-Identifier: LGPL-3.0-or-later *)

open Angstrom
open Ast

let pp_error ppf = function
  | `ParsingError s -> Format.fprintf ppf "%s" s
;;

type error = [ `ParsingError of string ]

(*application of operator to term*)
let chainl1 e op =
  let rec go acc =
    lift2 (fun f x -> Relation { atom = f; terms = [ acc; x ] }) op e
    >>= go
    <|> return acc
  in
  e >>= fun init -> go init
;;

let is_space = function
  | ' ' | '\t' | '\n' | '\r' -> true
  | _ -> false
;;

(*declare of all need var*)
let string_of_spase = take_while is_space
let token s = string_of_spase *> string s
let dot = string_of_spase *> char '.' *> string_of_spase
let bar = string_of_spase *> char '|' *> string_of_spase
let in_bracket x = string_of_spase *> char '(' *> x <* char '(' <* string_of_spase
let sqr_brackets x = string_of_spase *> char '[' *> x <* char ']' <* string_of_spase
let in_quotes x = string_of_spase *> char '\"' *> x <* char '\"' <* string_of_spase
let parens x = char '(' *> x <* char ')'
let underscore = string_of_spase *> token "_" <* string_of_spase
let name_c x = Name x
let num_c x = Num x
let atom_c x = Atom x
let var_c x = Var x
let oper_c x = Oper x
let comma_token = token "," >>| oper_c
let semicolon = token ";" >>| oper_c
let sign_rule = token ":-" >>| oper_c
let not = token "\\+" >>| oper_c
let eqq = token "==" <|> token "=" >>| oper_c
let assign = token "is" >>| oper_c
let request = token "?-" >>| oper_c

let aryth_oper =
  token "+"
  <|> token "-"
  <|> token "*"
  <|> token "/"
  <|> token "**"
  <|> token "//"
  <|> token "<"
  <|> token ">"
  >>| oper_c
;;

let is_letter_number = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
  | _ -> false
;;

let is_letter_cap = function
  | 'A' .. 'Z' -> true
  | _ -> false
;;

let is_letter_lower = function
  | 'a' .. 'z' -> true
  | _ -> false
;;

let is_number = function
  | '0' .. '9' -> true
  | _ -> false
;;

let isnot_letter_number = function
  | '#'
  | '$'
  | '&'
  | '*'
  | '+'
  | '-'
  | '.'
  | '/'
  | ':'
  | '<'
  | '='
  | '>'
  | '?'
  | '@'
  | '^'
  | '~' -> true
  | _ -> false
;;

let is_anything c = is_letter_number c || isnot_letter_number c

(*declare simple parsers*)
(*first case: base name of atom (starts with lowercase letter) or '!'; second case: name of atom is "string"; third case: empty atom*)
let atom =
  string_of_spase
  *> (satisfy (function
        | 'a' .. 'z' | '!' -> true
        | _ -> false)
      <|> satisfy isnot_letter_number)
  >>= (fun ch -> take_while is_letter_number >>| fun str -> String.make 1 ch ^ str)
  >>| name_c
  <|> (string_of_spase *> in_quotes (take_while is_anything <|> take_while is_space)
       >>= fun str -> return (String.concat str [ "\""; "\"" ]) >>| name_c)
  <|> (token "[]" >>| name_c)
;;

(*first case: atom; second case: number*)
let const =
  atom
  >>| atom_c
  <|> (string_of_spase *> take_while1 is_number >>| int_of_string >>| num_c)
;;

(*first case: anonymous variable; second case: base name of variable (starts with uppercase letter)*)
let var =
  underscore
  >>| var_c
  <|> string_of_spase
      *> (satisfy (function
            | 'A' .. 'Z' | '_' -> true
            | _ -> false)
          >>= (fun ch ->
                take_while is_letter_number >>| fun str -> String.make 1 ch ^ str)
          >>| var_c)
;;

let relation =
  fix (fun relation ->
    let create_relation atom terms = Relation { atom; terms } in
    let const = lift (fun x -> Const x) const in
    let request_term =
      let create_relation op term = create_relation op [ term ] in
      lift2 create_relation request relation
    in
    let term_with_prefix_op =
      let create_relation op term = create_relation op [ term ] in
      lift2 create_relation not relation
    in
    let term_in_func_notation =
      let args = parens (sep_by1 comma_token relation) in
      lift2 create_relation atom args
    in
    let term_in_list_notation =
      fix (fun term_in_list_notation ->
        let list_atom = Const (Atom (Name "[]")) in
        let list_c r1 r2 = Relation { atom = Name "."; terms = [ r1; r2 ] } in
        let term =
          term_in_list_notation
          <|> term_with_prefix_op
          <|> term_in_func_notation
          <|> const
          <|> var
        in
        let items =
          fix (fun items ->
            lift2 list_c (term <* comma_token) items
            <|> (lift2 list_c (term <* bar) term
                 <|> lift (fun r -> list_c r list_atom) term))
        in
        sqr_brackets items)
    in
    in_bracket
      (chainl1
         (chainl1
            (chainl1
               (chainl1 (chainl1 (chainl1 relation aryth_oper) assign) eqq)
               comma_token)
            sign_rule)
         request)
    <|> term_in_list_notation
    <|> term_with_prefix_op
    <|> term_in_func_notation
    <|> request_term
    <|> const
    <|> var)
;;

let term =
  chainl1
    (chainl1
       (chainl1 (chainl1 (chainl1 (chainl1 relation aryth_oper) assign) eqq) comma_token)
       sign_rule)
    request
  <* dot
;;

(*declare main parser*)
let many_term_c x = Many_term x
let parse_prolog = many1 term >>| many_term_c

let parse_program str =
  match parse_string ~consume:Consume.All parse_prolog str with
  | Ok x -> Ok x
  | Error er -> Error (`ParsingError er)
;;

let parse_query str =
  match parse_string ~consume:Consume.All term str with
  | Ok x -> Ok x
  | Error er -> Error (`ParsingError er)
;;
