(* ::Package:: *)

(* Wolfram Language Server Specification *)
(* Author: kenkangxgwe <kenkangxgwe_at_gmail.com>, 
           huxianglong <hxianglong_at_gmail.com>
*)


BeginPackage["WolframLanguageServer`Specification`"];

ClearAll["WolframLanguageServer`Specification`*"];


(* ::Section:: *)
(*ErrorCode*)


ErrorDict = <|
	"ParseError" -> -32700,
	"InvalidRequest" -> -32600,
	"MethodNotFound" -> -32601,
	"InvalidParams" -> -32602,
	"InternalError" -> -32603,
	"serverErrorStart" -> -32099,
	"serverErrorEnd" -> -32000,
	"ServerNotInitialized" -> -32002,
	"UnknownErrorCode" -> -32001,
	"RequestCancelled" -> -32800
|>;

ErrorTypeQ[type_String] := MemberQ[Keys[ErrorDict], type];

(* ::Section:: *)
(*Server Communication Related Type*)
DeclareType[WorkState, <|"initialized" -> _?BooleanQ, "openedDocs" -> _Association|>];
DeclareType[TextDocument, <|"text" -> _String, "version" -> _Integer, "position"->_List|>];

EndPackage[];