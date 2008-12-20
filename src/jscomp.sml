(* Copyright (c) 2008, Adam Chlipala
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 * - Redistributions of source code must retain the above copyright notice,
 *   this list of conditions and the following disclaimer.
 * - Redistributions in binary form must reproduce the above copyright notice,
 *   this list of conditions and the following disclaimer in the documentation
 *   and/or other materials provided with the distribution.
 * - The names of contributors may not be used to endorse or promote products
 *   derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR 
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *)

structure JsComp :> JSCOMP = struct

open Mono

structure EM = ErrorMsg
structure E = MonoEnv
structure U = MonoUtil

type state = {
     decls : decl list,
     script : string
}

fun varDepth (e, _) =
    case e of
        EPrim _ => 0
      | ERel _ => 0
      | ENamed _ => 0
      | ECon (_, _, NONE) => 0
      | ECon (_, _, SOME e) => varDepth e
      | ENone _ => 0
      | ESome (_, e) => varDepth e
      | EFfi _ => 0
      | EFfiApp (_, _, es) => foldl Int.max 0 (map varDepth es)
      | EApp (e1, e2) => Int.max (varDepth e1, varDepth e2)
      | EAbs _ => 0
      | EUnop (_, e) => varDepth e
      | EBinop (_, e1, e2) => Int.max (varDepth e1, varDepth e2)
      | ERecord xes => foldl Int.max 0 (map (fn (_, e, _) => varDepth e) xes)
      | EField (e, _) => varDepth e
      | ECase (e, pes, _) =>
        foldl Int.max (varDepth e)
        (map (fn (p, e) => E.patBindsN p + varDepth e) pes)
      | EStrcat (e1, e2) => Int.max (varDepth e1, varDepth e2)
      | EError (e, _) => varDepth e
      | EWrite e => varDepth e
      | ESeq (e1, e2) => Int.max (varDepth e1, varDepth e2)
      | ELet (_, _, e1, e2) => Int.max (varDepth e1, 1 + varDepth e2)
      | EClosure _ => 0
      | EQuery _ => 0
      | EDml _ => 0
      | ENextval _ => 0
      | EUnurlify _ => 0
      | EJavaScript _ => 0
      | ESignalReturn e => varDepth e

fun strcat loc es =
    case es of
        [] => (EPrim (Prim.String ""), loc)
      | [x] => x
      | x :: es' => (EStrcat (x, strcat loc es'), loc)

fun jsExp mode outer =
    let
        val len = length outer

        fun jsE inner (e as (_, loc), st) =
            let
                fun str s = (EPrim (Prim.String s), loc)

                fun var n = Int.toString (len + inner - n - 1)

                fun patCon pc =
                    case pc of
                        PConVar n => str (Int.toString n)
                      | PConFfi {con, ...} => str ("\"_" ^ con ^ "\"")



                fun isNullable (t, _) =
                    case t of
                        TOption _ => true
                      | _ => false

                fun unsupported s =
                  (EM.errorAt loc (s ^ " in code to be compiled to JavaScript");
                   (str "ERROR", st))

                val strcat = strcat loc
            in
                case #1 e of
                    EPrim (Prim.String s) =>
                    (str ("\""
                          ^ String.translate (fn #"'" =>
                                                 if mode = Attribute then
                                                     "\\047"
                                                 else
                                                     "'"
                                               | #"<" =>
                                                 if mode = Script then
                                                     "<"
                                                 else
                                                     "\\074"
                                               | #"\\" => "\\\\"
                                               | ch => String.str ch) s
                          ^ "\""), st)
                  | EPrim p => (str (Prim.toString p), st)
                  | ERel n =>
                    if n < inner then
                        (str ("uwr" ^ var n), st)
                    else
                        (str ("uwo" ^ var n), st)
                  | ENamed _ => raise Fail "Named"
                  | ECon (_, pc, NONE) => (patCon pc, st)
                  | ECon (_, pc, SOME e) =>
                    let
                        val (s, st) = jsE inner (e, st)
                    in
                        (strcat [str "{n:",
                                 patCon pc,
                                 str ",v:",
                                 s,
                                 str "}"], st)
                    end
                  | ENone _ => (str "null", st)
                  | ESome (t, e) =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (if isNullable t then
                             strcat [str "{v:", e, str "}"]
                         else
                             e, st)
                    end

                  | EFfi (_, s) => (str s, st)
                  | EFfiApp (_, s, []) => (str (s ^ "()"), st)
                  | EFfiApp (_, s, [e]) =>
                    let
                        val (e, st) = jsE inner (e, st)
                        
                    in
                        (strcat [str (s ^ "("),
                                 e,
                                 str ")"], st)
                    end
                  | EFfiApp (_, s, e :: es) =>
                    let
                        val (e, st) = jsE inner (e, st)
                        val (es, st) = ListUtil.foldlMapConcat
                                           (fn (e, st) =>
                                               let
                                                   val (e, st) = jsE inner (e, st)
                                               in
                                                   ([str ",", e], st)
                                               end)
                                           st es
                    in
                        (strcat (str (s ^ "(")
                                 :: e
                                 :: es
                                 @ [str ")"]), st)
                    end

                  | EApp (e1, e2) =>
                    let
                        val (e1, st) = jsE inner (e1, st)
                        val (e2, st) = jsE inner (e2, st)
                    in
                        (strcat [e1, str "(", e2, str ")"], st)
                    end
                  | EAbs (_, _, _, e) =>
                    let
                        val locals = List.tabulate
                                     (varDepth e,
                                   fn i => str ("var uwr" ^ Int.toString (len + inner + i) ^ ";"))
                        val (e, st) = jsE (inner + 1) (e, st)
                    in
                        (strcat (str ("function(uwr"
                                      ^ Int.toString (len + inner)
                                      ^ "){")
                                 :: locals
                                 @ [str "return ",
                                    e,
                                    str "}"]),
                         st)
                    end

                  | EUnop (s, e) =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (strcat [str ("(" ^ s),
                                 e,
                                 str ")"],
                         st)
                    end
                  | EBinop (s, e1, e2) =>
                    let
                        val (e1, st) = jsE inner (e1, st)
                        val (e2, st) = jsE inner (e2, st)
                    in
                        (strcat [str "(",
                                 e1,
                                 str s,
                                 e2,
                                 str ")"],
                         st)
                    end

                  | ERecord [] => (str "null", st)
                  | ERecord [(x, e, _)] =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (strcat [str "{uw_x:", e, str "}"], st)
                    end
                  | ERecord ((x, e, _) :: xes) =>
                    let
                        val (e, st) = jsE inner (e, st)

                        val (es, st) =
                            foldr (fn ((x, e, _), (es, st)) =>
                                      let
                                          val (e, st) = jsE inner (e, st)
                                      in
                                          (str (",uw_" ^ x ^ ":")
                                           :: e
                                           :: es,
                                           st)
                                      end)
                                  ([str "}"], st) xes
                    in
                        (strcat (str ("{uw_" ^ x ^ ":")
                                 :: e
                                 :: es),
                         st)
                    end
                  | EField (e, x) =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (strcat [e,
                                 str ("." ^ x)], st)
                    end

                  | ECase _ => raise Fail "Jscomp: ECase"

                  | EStrcat (e1, e2) =>
                    let
                        val (e1, st) = jsE inner (e1, st)
                        val (e2, st) = jsE inner (e2, st)
                    in
                        (strcat [str "(", e1, str "+", e2, str ")"], st)
                    end

                  | EError (e, _) =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (strcat [str "alert(\"ERROR: \"+", e, str ")"],
                         st)
                    end

                  | EWrite e =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (strcat [str "document.write(",
                                 e,
                                 str ")"], st)
                    end

                  | ESeq (e1, e2) =>
                    let
                        val (e1, st) = jsE inner (e1, st)
                        val (e2, st) = jsE inner (e2, st)
                    in
                        (strcat [str "(", e1, str ",", e2, str ")"], st)
                    end
                  | ELet (_, _, e1, e2) =>
                    let
                        val (e1, st) = jsE inner (e1, st)
                        val (e2, st) = jsE (inner + 1) (e2, st)
                    in
                        (strcat [str ("(uwr" ^ Int.toString (len + inner) ^ "="),
                                 e1,
                                 str ",",
                                 e2,
                                 str ")"], st)
                    end

                  | EClosure _ => unsupported "EClosure"
                  | EQuery _ => unsupported "Query"
                  | EDml _ => unsupported "DML"
                  | ENextval _ => unsupported "Nextval"
                  | EUnurlify _ => unsupported "EUnurlify"
                  | EJavaScript _ => unsupported "Nested JavaScript"
                  | ESignalReturn e =>
                    let
                        val (e, st) = jsE inner (e, st)
                    in
                        (strcat [(*str "sreturn(",*)
                                 e(*,
                                 str ")"*)],
                         st)
                    end
            end
    in
        jsE
    end

val decl : state -> decl -> decl * state =
    U.Decl.foldMapB {typ = fn x => x,
                     exp = fn (env, e, st) =>
                              let
                                  fun doCode m env e =
                                      let
                                          val len = length env
                                          fun str s = (EPrim (Prim.String s), #2 e)

                                          val locals = List.tabulate
                                                           (varDepth e,
                                                         fn i => str ("var uwr" ^ Int.toString (len + i) ^ ";"))
                                          val (e, st) = jsExp m env 0 (e, st)
                                      in
                                          (#1 (strcat (#2 e) (locals @ [e])), st)
                                      end
                              in
                                  case e of
                                      EJavaScript (m, (EAbs (_, t, _, e), _)) => doCode m (t :: env) e
                                    | EJavaScript (m, e) => doCode m env e
                                    | _ => (e, st)
                              end,
                     decl = fn (_, e, st) => (e, st),
                     bind = fn (env, U.Decl.RelE (_, t)) => t :: env
                             | (env, _) => env}
                    []

fun process file =
    let
        fun doDecl (d, st) =
            let
                val (d, st) = decl st d
            in
                (List.revAppend (#decls st, [d]),
                 {decls = [],
                  script = #script st})
            end

        val (ds, st) = ListUtil.foldlMapConcat doDecl
                       {decls = [],
                        script = ""}
                       file
    in
        ds
    end

end
