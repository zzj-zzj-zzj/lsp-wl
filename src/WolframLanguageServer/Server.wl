(* ::Package:: *)

(* Wolfram Language Server *)
(* Author: kenkangxgwe <kenkangxgwe_at_gmail.com>,
           huxianglong <hxianglong_at_gmail.com>
*)


BeginPackage["WolframLanguageServer`Server`"];
ClearAll[Evaluate[Context[] <> "*"]];


(* Output Symbols *)
WLServerStart::usage = "WLServerStart[] starts a Wolfram Language Server with given option association.";
WLServerVersion::usage = "WLServerVersion[] gives the version of the current Wolfram Language Server.";
WLServerDebug::usage = "WLServerDebug[] is a debug-only function to expose private context";


(* Private Context *)
Begin["`Private`"];
ClearAll[Evaluate[Context[] <> "*"]];


Needs["DataType`"]
Needs["WolframLanguageServer`Logger`"]
Needs["WolframLanguageServer`Specification`"]
Needs["WolframLanguageServer`TextDocument`"]
Needs["WolframLanguageServer`Token`"]


(* ::Section:: *)
(*Utility*)


FoldWhile[f_, x_, list_List, test_] := FoldWhile[f, Prepend[list, x], test];
FoldWhile[f_, list_List, test_] := First[NestWhile[Prepend[Drop[#, 2], f @@ Take[#, 2]]&, list, Length[#] > 1 && test[First[#]]&]];


(* ::Section:: *)
(*Start Server*)


DeclareType[WorkState, <|
	"initialized" -> _?BooleanQ,
	"openedDocs" -> _Association, (* (_DocumentUri -> _DocumentText)... *)
	"client" -> (_SocketClient | _SocketObject | _NamedPipe | _StdioClient | "stdio" | Null),
	"clientCapabilities" -> _Association,
	"scheduledTasks" -> {___ServerTask},
	"caches" -> _Association,
	"config" -> _Association
|>]


DeclareType[RequestCache, <|
	"cachedTime" -> _DateObject,
	"result" -> _,
	"error" -> _Association
|>]

initialCaches = <|
	"textDocument/signatureHelp" -> <||>,
	"textDocument/documentSymbol" -> <||>,
	"textDocument/documentColor" -> <||>,
	"textDocument/codeLens" -> <||>,
	"textDocument/publishDiagnostics" -> <||>
|>

InitialState = WorkState[<|
	"initialized" -> False,
	"openedDocs" -> <||>,
	"client" -> Null,
	"scheduledTasks" -> {},
	"caches" -> initialCaches,
	"config" -> <|
		"configFileConfig" -> loadConfig[]
	|>
|>]

ServerCapabilities = <|
	"textDocumentSync" -> TextDocumentSyncKind["Full"],
	"hoverProvider" -> True,
	"signatureHelpProvider" -> <|
		"triggerCharacters" -> {"[", ","}
	|>,
	"completionProvider" -> <|
		"resolveProvider" -> True,
		"triggerCharacters" -> {"\\"}
	|>,
	"definitionProvider" -> True,
	"referencesProvider" -> True,
	"documentSymbolProvider" -> True,
	"documentHighlightProvider" -> True,
	"colorProvider" -> True,
	(* "executeCommandProvider" -> <|
		"commands" -> {
			"openRef"
		}
	|>, *)
	Nothing
|>

ServerConfig = <|
	"updateCheckInterval" -> Quantity[7, "Days"],
		(* cached results *)
	"cachedRequests" -> {
		"textDocument/signatureHelp",
		"textDocument/documentSymbol",
		"textDocument/documentColor"
		(* "textDocument/codeLens" *)
	},
	"delayedRequests" -> {
		"textDocument/documentHighlight",
		"textDocument/documentColor"
	},
	(* default delays (seconds) *)
	"requestDelays" -> <|
		"textDocument/publishDiagnostics" -> 2.5,
		"textDocument/signatureHelp" -> 0.5,
		"textDocument/documentSymbol" -> 4.0,
		"textDocument/documentHighlight" -> 0.5,
		"textDocument/documentColor" -> 5.0
	|>
|>


(* ::Section:: *)
(*WLServer*)


(* ::Subsection:: *)
(*WLServerStart*)


Options[WLServerStart] = {
	"Stream" -> "socket" (* "stdio" is no implemented *),
	"ClientPid" -> Null,
	"Port" -> 6536,
	"Pipe" -> Null,
	"WorkingDir" -> $TemporaryDirectory
};

WLServerStart[o:OptionsPattern[]] := Module[
	{
		tempDirPath, connection, stdin, stdout, readpipe,
		(*Options:*) clientPid, port, pipe, stream, workingDir
	},

	{stream, clientPid, port, pipe, workingDir} = OptionValue[WLServerStart, {o}, {"Stream", "ClientPid", "Port", "Pipe", "WorkingDir"}];
    If[clientPid === Null, clientPid = GetParentPid[]];
	(* If[FileExistsQ[Last @ $Path <> "Cache"], LogError @ "Please delete a file named cache in working directory first."]; *)
    
	(*Temporary cache.*)
	tempDirPath = FileNameJoin[{workingDir, "wlServerCache"}];
	
	If[DirectoryQ[tempDirPath],
	    (*Clear the cache of last time usage.*)
	    DeleteDirectory[tempDirPath, DeleteContents -> True],
    	(*Create temporary file.*)
		CreateDirectory[tempDirPath]
		// Replace[$Failed :> (
		    LogError["Create cache directory failed, please make sure there is no file named cache in the working directory."];
		    Quit[1]
		)]
	];
	
	LogInfo["Language server is connecting the client through "<> stream <> "."];
	Replace[stream, {
	    "stdio" :> (
	        LogError["Communication through " <> stream <> " is not implemented"];
	        Quit[1]
	    ),
		"stdio" :> (
		    (* stdin is a InputStream connecting to the STDOUT of the client, vice versa *)
		    connection = StartProcess[{"D:\\Programs\\msys64\\usr\\bin\\cat.exe"}]
		    // Replace[{
		        {proc_} :> proc,
		        {} :> (LogError["Cannot find client process."]; Quit[1])
		    }];
		    stdin = LogDebug@Check[t`stdin = ProcessConnection[connection, "StandardOutput"], Nothing];
			stdout = LogDebug@Check[t`stdout = OutputStream["stdout", 1], Nothing];
			LogInfo["Server listening from pid " <> ToString[clientPid] <> "..."];
			Block[{$IterationLimit = Infinity},
				InitialState
			    // ReplaceKey["client" -> "stdio" (*StdioClient[<|"process" -> connection, "stdin" -> stdin, "stdout" -> stdout|>]*)]
				// StdioHandler
			]
	    ),
	    "pipe" :> (
			Replace[$OperatingSystem, {
				"Windows" :> (
					pipe
					// StringCases["\\\\.\\pipe\\"~~pipename__ :> pipename]
					// Replace[{
						{pipename_String} :> (
							Needs["NETLink`"];
							NETLink`InstallNET[];
							(* Cannot load type for the first run *)
							NETLink`LoadNETType["System.Byte[]"];
							NETLink`LoadNETType["System.IO.Pipes.PipeDirection"];
							NETLink`BeginNETBlock[];
							Check[
								connection = t`conn = NETLink`NETNew["System.IO.Pipes.NamedPipeClientStream", ".", pipename, PipeDirection`InOut];
								connection@Connect[2000],
								$Failed
							] // Replace[$Failed :> (LogError["Cannot connect to named pipe."]; Quit[1])];

							LogInfo["Server listening on pipe " <> pipename <> "..."];
							(*LogInfo[WLServerListen[connection, InitialState]];*)

							Block[{$IterationLimit = Infinity},
								InitialState
								// ReplaceKey["client" -> NamedPipe[<|
									"pipeName" -> pipename, "pipeStream" -> connection
								|>]]
								// TcpSocketHandler
							]
						),
						{} :> (
							(* pipe name error *)
							LogError["Wrong pipe name"];
						)
					}]
				)
			}];
	    ),
	    "tcp-server" :> (
	        connection = Check[t`conn = SocketOpen[port, "TCP"(*"ZMQ_Stream"*)], $Failed]
			// Replace[$Failed :> (LogError["Cannot start tcp server."]; Quit[1])];

	        LogInfo["Server listening on port " <> ToString[port] <> "..."];
	        (*LogInfo[WLServerListen[connection, InitialState]];*)
    
            Block[{$IterationLimit = Infinity},
				InitialState
				// ReplaceKey["client" -> waitForClient[connection]]
				// TcpSocketHandler
        	]
	    ),
		"socket" :> (
			connection = Check[t`conn = SocketConnect[port, "TCP"(*"ZMQ_Stream"*)], $Failed]
			// Replace[$Failed :> (LogError["Cannot connect to client via socket."]; Quit[1])];
			
	        LogInfo["Server listening from port " <> ToString[port] <> "..."];
	        (*LogInfo[WLServerListen[connection, InitialState]];*)
    
            Block[{$IterationLimit = Infinity},
				InitialState
				// ReplaceKey["client" -> connection]
				// TcpSocketHandler
        	]
        ),
        _ :> (
            LogError[stream <> "is invalid."];
            Quit[1]
        )
	}]
	// Replace[{
		{"Stop", _} :> (
	        LogInfo["Server stopped normally."];
			Quit[0]
		),
		{err_, _} :> (
	        LogError["Server stopped abnormally."];
	        LogError[err];
			Quit[1]
		)
	}]

	(*Block[{serverState = InitialState},
		SocketListen[connection, SocketHandler,
			HandlerFunctionsKeys -> {"SourceSocket", "DataByteArray", "DataBytes", "MultipartComplete"}
		]
	]*)
	
]


waitForClient[{client_SocketObject}] := (LogInfo["Client connected"]; client);
waitForClient[server_SocketObject] := waitForClient[Replace[server["ConnectedClients"],{
    {} :> (Pause[1]; (* LogInfo["Waiting for connection from client"]; *) server),
    {client_SocketObject} :> {client}
}]]


GetParentPid[] := (
    SystemProcesses["PID" -> $ProcessID]
    // Replace[{
        {} :> Null,
        {proc_} :> proc["PPID"]
    }]
)


(* ::Subsection:: *)
(*WLServerListen*)


(* ::Subsubsection:: *)
(*ZMQ  (not working)*)


DeclareType[SocketClient, <|
	"lastMessage" -> _String,
	"zmqIdentity" -> (_ByteArray | Null),
	"contentLengthRemain" -> _Integer,
	"socket" -> _SocketObject
|>]

DeclareType[NamedPipe, <|
	"pipeStream" -> _?(NETLink`InstanceOf[#, "System.IO.Pipes.NamedPipeClientStream"]&),
	"pipeName" -> _String
|>]


(* Not using this handler due to ZMQ is not supported yet, please see handler for TCP *)
SocketHandler[packet_Association] := Module[
	{
		bytearray = packet["DataByteArray"],
		client = serverState["client"],
		headerEndPosition, headertext, contentlength,
		consumelength, message,
		serverStatus
	},

	If[client === Null,
		client = SocketClient[<|
			"socket" -> packet["SourceSocket"]
		|>]
	];
	
	If[Length[bytearray] == 5 && First @ Normal @ bytearray == 0,
		(* ZMQ_Identity *)
		LogDebug@"ZMQ_Identity Received";
		client = ReplaceKey[client, "zmqIdentity" -> bytearray];
		serverState = ReplaceKey[serverState, "client" -> client];
		Return[];
	];
	
	If[client["contentLengthRemain", 0] == 0,
	(* content-length *)
		client = Check[
			headerEndPosition = SequencePosition[Normal @ bytearray, RPCPatterns["SequenceSplitPattern"], 1];
			headertext = ByteArrayToString[bytearray, "ASCII"];
			contentlength = ToExpression[First @ StringCases[headertext, RPCPatterns["ContentLengthRule"]]];
			(* LogDebug["Content Length: " <> ToString[contentlength]]; *)
			Fold[ReplaceKey, client, {
				"contentLengthRemain" -> contentlength,
				"lastMessage" -> ""
			}],
			LogWarn["Invalid Message" <> ToString @ Normal @ bytearray];
			client
		];
		serverState = ReplaceKey[serverState, "client" -> client];
		Return[];
	];
	
	(* consume more messages *)
	consumelength = Min[Length[bytearray], client["contentLengthRemain"]];
	client = Fold[ReplaceKey, client, {
		"lastMessage" -> client["lastMessage"] <> ByteArrayToString[Take[bytearray, consumelength]],
		"contentLengthRemain" -> client["contentLengthRemain"] - consumelength
	}];
	serverState = ReplaceKey[serverState, "client" -> client];
	
	If[client["contentLengthRemain"] != 0,
		Return[];
	];
	
	(* ready to handle *)
	message = ImportString[client["lastMessage"], "RawJSON"];

	{serverStatus, serverState} = handleMessage[message, serverState];
	If[serverStatus === "Stop",
		LogInfo["Server stopped. Last Message: " <> message];
		Return[];
	];

];


(* ::Subsubsection:: *)
(*Tcp Socket*)


TcpSocketHandler[{stop_, state_WorkState}]:= (
    (* close client and return *)
    LogInfo["Closing socket connection..."];
	CloseClient[state["client"]];
    {stop, state}
)
TcpSocketHandler[state_WorkState] := Module[
	{
		client = state["client"]
	},

	If[SocketReadyQ[client],
		handleMessageList[ReadMessages[client], state],
		doNextScheduledTask[state]
	]
	// Replace[{
		{"Continue", newstate_} :> newstate,
		{stop_, newstate_} :> (
			{stop, newstate}
		),
		{} :> state, (* No message *)
		err_ :> {LogError[err], state}
	}]
] // TcpSocketHandler (* Put the recursive call out of the module to turn on the tail-recursion optimization *)


(* ::Subsubsection:: *)
(*Stdio (not working)*)


DeclareType[StdioClient, <|
	"lastMessage" -> _ByteArray | {},
	"contentLengthRemain" -> _Integer,
	"process" -> _ProcessObject,
	"stdin" -> _InputStream,
	"stdout" -> _OutputStream
|>];

StdioHandler[state_WorkState] := Module[
	{
		client = state["client"]
	},

	handleMessageList[ReadMessages[client], state]
	// Replace[{
	    {"Stop", newstate_} :> (
	        LogInfo["Server stopped"];
			Return[newstate]
	    ),
	    {_, newstate_} :> newstate,
	    {} :> state (* No message *)
	}]
] // StdioHandler; (* Put the recursive call out of the module to turn on the tail-recursion optimization *)


(* ::Section:: *)
(*StreamIO*)


StreamPattern = ("stdio"|_SocketObject);


(* ::Subsection:: *)
(*SelectClient*)


SelectClient[connection_SocketObject] := (	
	SelectFirst[connection["ConnectedClients"], SocketReadyQ] (* SocketWaitNext does not work in 11.3 *)
	// (If[MissingQ[#],
		Pause[1];
		Return[SelectClient[connection]],
		#
	]&)
);
SelectClient["stdio"] := "stdio";


(* ::Subsection:: *)
(*ReadMessage*)


(* ::Subsubsection:: *)
(*Socket*)


ReadMessages[client_SocketObject] := ReadMessagesImpl[client, {{0, {}}, {}}]
ReadMessagesImpl[client_SocketObject, {{0, {}}, msgs:{__Association}}] := msgs
ReadMessagesImpl[client_SocketObject, {{remainingLength_Integer, remainingByte:(_ByteArray|{})}, {msgs___Association}}] := ReadMessagesImpl[client, (
    If[remainingLength > 0,
        (* Read Content *)
        If[Length[remainingByte] >= remainingLength,
            {{0, Drop[remainingByte, remainingLength]}, {msgs, ImportByteArray[Take[remainingByte, remainingLength], "RawJSON"]}},
            (* Read more *)
            {{remainingLength, ByteArray[remainingByte ~Join~ SocketReadMessage[client]]}, {msgs}}
        ],
        (* New header *)
        Replace[SequencePosition[Normal @ remainingByte, RPCPatterns["SequenceSplitPattern"], 1], {
	        {{end1_, end2_}} :> (
	            {{getContentLength[Take[remainingByte, end1 - 1]], Drop[remainingByte, end2]}, {msgs}}
	        ),
	        {} :> ( (* Read more *)
	            {{0, ByteArray[remainingByte ~Join~ SocketReadMessage[client]]}, {msgs}}
		    )
	    }]
	]
)]


(* ::Subsubsection:: *)
(*NamedPipe*)


ReadMessages[client_NamedPipe] := {ReadMessagesImpl[client, {}]}
ReadMessagesImpl[client_NamedPipe, msg_Association] := msg
ReadMessagesImpl[client_NamedPipe, header_List] := ReadMessagesImpl[client, Module[
    {
		pipeStream = client["pipeStream"],
        newByteArray
    },

    If[MatchQ[header, {RPCPatterns["HeaderByteArray"]}],
        (* read content *)
		With[{contentLength = header // ByteArray // getContentLength}, NETLink`NETBlock[
			newByteArray = NETLink`NETNew["System.Byte[]", contentLength];
			pipeStream@Read[newByteArray, 0, contentLength];
			ImportByteArray[ByteArray[NETLink`NETObjectToExpression[newByteArray]], "RawJSON"]
		]],
        (* read header *)
		Append[header, pipeStream@ReadByte[]]
	]
]]


(* ::Subsubsection:: *)
(*StdioClient*)


ReadMessages[client_StdioClient] := ReadMessagesImpl["stdio", {{0, {}}, {}}]
ReadMessagesImpl[client_StdioClient, {{0, {}}, msgs:{__Association}}] := msgs
ReadMessagesImpl[client_StdioClient, {{remainingLength_Integer, remainingByte:(_ByteArray|{})}, {msgs___Association}}] := ReadMessagesImpl[client, Module[
    {
    },
    
    (* LogDebug @ {remainingLength, Normal[remainingByte]}; *)
    If[remainingLength > 0,
        (* Read Content *)
        If[Length[remainingByte] >= remainingLength,
            {{0, Drop[remainingByte, remainingLength]}, {msgs, ImportByteArray[Take[remainingByte, remainingLength], "RawJSON"]}},
            (* Read more *)
            {{remainingLength, ByteArray[remainingByte ~Join~ InputBinary[]]}, {msgs}}
        ],
        (* New header *)
        Replace[SequencePosition[Normal @ remainingByte, RPCPatterns["SequenceSplitPattern"], 1], {
	        {{end1_, end2_}} :> (
	            {{getContentLength[Take[remainingByte, end1 - 1]], Drop[remainingByte, end2]}, {msgs}}
	        ),
	        {} :> ( (* Read more *)
	            {{0, ByteArray[remainingByte ~Join~ InputBinary[]]}, {msgs}}
		    )
	    }]
	]
]]


(* ::Subsubsection:: *)
(*stdio*)


ReadMessages["stdio"] := ReadMessagesImpl["stdio", {{0, {}}, {}}]
ReadMessagesImpl["stdio", {{0, {}}, msgs:{__Association}}] := msgs
ReadMessagesImpl["stdio", {{remainingLength_Integer, remainingByte:(_ByteArray|{})}, {msgs___Association}}] := ReadMessagesImpl["stdio", (
    (* LogDebug @ {remainingLength, Normal[remainingByte]}; *)
    If[remainingLength > 0,
        (* Read Content *)
        If[Length[remainingByte] >= remainingLength,
            {{0, Drop[remainingByte, remainingLength]}, {msgs, ImportByteArray[Take[remainingByte, remainingLength], "RawJSON"]}},
            (* Read more *)
            {{remainingLength, ByteArray[remainingByte ~Join~ InputBinary[]]}, {msgs}}
        ],
        (* New header *)
        Replace[SequencePosition[Normal @ remainingByte, RPCPatterns["SequenceSplitPattern"], 1], {
	        {{end1_, end2_}} :> (
	            {{getContentLength[Take[remainingByte, end1 - 1]], Drop[remainingByte, end2]}, {msgs}}
	        ),
	        {} :> ( (* Read more *)
	            {{0, ByteArray[remainingByte ~Join~ InputBinary[]]}, {msgs}}
		    )
	    }]
	]
)]


InputBinary[] := (LogDebug["waiting for input"];a=Import["!D:\\Programs\\msys64\\usr\\bin\\cat.exe", "Byte"];LogDebug["input done"];a)(*(LogDebug["waiting for input"]; ByteArray[StringToByteArray[InputString[]] ~Join~ {13, 10}])*)


(* ::Subsection:: *)
(*WriteMessage*)


WriteMessage[client_SocketClient][msglist:{__ByteArray}] := Module[
	{
		targetsocket
	},
	
	targetsocket = client["socket"];
	BinaryWrite[targetsocket, client["zmqIdentity"]];
	BinaryWrite[targetsocket, First@msglist];
	BinaryWrite[targetsocket, client["zmqIdentity"]];
	BinaryWrite[targetsocket, Last@msglist];
]


WriteMessage[client_NamedPipe][msglist:{header_ByteArray, content_ByteArray}] := With[
	{
		pipeStream = client["pipeStream"]
	},
	
	pipeStream@Write[Normal[header], 0, Length[header]];
	pipeStream@Write[Normal[content], 0, Length[content]];
	pipeStream@Flush[];

]


WriteMessage[client_SocketObject][msglist:{__ByteArray}] := (
    BinaryWrite[client, First@msglist];
    BinaryWrite[client, Last@msglist];
);


WriteMessage["stdio"][msglist:{__ByteArray}] := (
    BinaryWrite[OutputStream["stdout",1], First@msglist];
    BinaryWrite[OutputStream["stdout",1], Last@msglist];
);


WriteMessage[client_StdioClient][msg_ByteArray] := BinaryWrite[client["stdout"], msg];


(* ::Section:: *)
(*JSON - RPC*)


RPCPatterns = <|
	"HeaderByteArray" -> PatternSequence[__, 13, 10, 13, 10],
	"SequenceSplitPattern" -> {13, 10, 13, 10},
	"ContentLengthRule" -> "Content-Length: "~~length:NumberString :> length,
	"ContentTypeRule" -> "Content-Type: "~~type_ :> type
|>;


constructRPCBytes[msg_Association] := (
	Check[
		ExportByteArray[msg, "RawJSON"],
		(*
			if the result is not able to convert to JSON,
			returns an error respond
		*)
		LogError[msg];
		ExportByteArray[
			msg
			// KeyDrop["result"]
			// Append["error" -> ServerError[
				"InternalError",
				"The request is not handled correctly."
			]],
		"RawJSON"]
	] // {
		(* header *)
		Length
		/* StringTemplate["Content-Length: `1`\r\n\r\n"]
		/* StringToByteArray,
		(* content *)
		Identity
	} // Through
)


getContentLength[header_ByteArray] := getContentLength[ByteArrayToString[header, "ASCII"]];
getContentLength[header_String] := (
	header
	// StringCases[RPCPatterns["ContentLengthRule"]]
	// Replace[{
		{len_String} :> ToExpression[len],
		_ :> (LogError["Unknown header: " <> header]; Quit[1])
	}]
)


(* :: Section:: *)
(*Close client*)


CloseClient[client_SocketObject] := Close /@ Sockets[]
CloseClient[client_NamedPipe] := With[
	{
		pipeStream = client["pipeStream"]
	},

	pipeStream@Close[];
	NETLink`EndNETBlock[]
]


(* ::Section:: *)
(*Handle Message*)


NotificationQ = KeyExistsQ["id"] /* Not
(* NotificationQ[msg_Association] := MissingQ[msg["id"]] *)

handleMessageList[msgs:{___Association}, state_WorkState] := (
    FoldWhile[handleMessage[#2, Last[#1]]&, {"Continue", state}, msgs, MatchQ[{"Continue", _}]]
);

handleMessage[msg_Association, state_WorkState] := With[
	{
		method = msg["method"]
	},

	Which[
		(* wrong message before initialization *)
		!state["initialized"] && !MemberQ[{"initialize", "initialized", "exit"}, method],
		If[!NotificationQ[msg],
			sendResponse[state["client"], <|
				"id" -> msg["id"],
				"error" -> ServerError[
					"ServerNotInitialized",
					"The server is not initialized."
				]
			|>]
			(* otherwise, dropped the notification *)
		];
		{"Continue", state},
		(* notification*)
		NotificationQ[msg],
		handleNotification[method, msg, state],
		(* resquest *)
		True,
		Which[
			MemberQ[ServerConfig["cachedRequests"], method] &&
			cacheAvailableQ[method, msg, state],
			LogInfo["Sending cached results of " <> ToString[method]];
			sendCachedResult[method, msg, state],
			MemberQ[ServerConfig["delayedRequests"], method],
			scheduleDelayedRequest[method, msg, state],
			True,
			handleRequest[method, msg, state]
		]
	]
];



(* ::Section:: *)
(*Handle Requests*)


(* generic currying *)
cacheResponse[method_String, msg_][state_WorkState] =
	cacheResponse[method, msg, state]


sendCachedResult[method_String, msg_, state_WorkState] := Block[
	{
		cache = getCache[method, msg, state]
	},

	sendResponse[state["client"],
		<|"id" -> msg["id"]|>
		// Append[
			If[!MissingQ[cache["result"]],
				"result" -> cache["result"],
				"error" -> cache["error"]
			]
		]
	];

	{"Continue", state}
]


scheduleDelayedRequest[method_String, msg_, state_WorkState] := (
	{
		"Continue",
		
		addScheduledTask[state, ServerTask[<|
			"type" -> method,
			"scheduledTime" -> DatePlus[Now, {
				ServerConfig["requestDelays"][method],
				"Second"
			}],
			"id" -> msg["id"],
			"params" -> getScheduleTaskParameter[method, msg, state],
			"callback" -> (handleRequest[method, msg, #1]&)
		|>]]
	}
)


(* response, notification and request will call this function *)
sendResponse[client_, res_Association] := (
	Prepend[res, <|"jsonrpc" -> "2.0"|>]
	// constructRPCBytes
	// WriteMessage[client]
)


(* ::Subsection:: *)
(*initialize*)


handleRequest["initialize", msg_, state_WorkState] := Module[
	{
		newState = state
	},

	LogDebug["handle/initialize"];
	
	(* Check Client Capabilities *)
	newState = ReplaceKey[state,
		"clientCapabilities" -> msg["params"]["capabilities"]
	];
	
	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> <|
			"capabilities" -> ServerCapabilities
		|>
	|>];
	
	{"Continue", newState}
];


(* ::Subsection:: *)
(*shutdown*)


handleRequest["shutdown", msg_, state_] := Module[
	{
	},

	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> Null
	|>];

	{"Continue", state}
];


(* ::Subsection:: *)
(*workspace/executeCommand*)


handleRequest["workspace/executeCommand", msg_, state_] := With[
	{
		command = msg["params"]["command"],
		args = msg["params"]["arguments"]
	},

	Replace[command, {
		"dap-wl.runfile" -> (
			LogInfo[StringJoin["executing ", command, "with arguments: ", ToString[args]]]
		)
	}];

	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> Null
	|>];

	{"Continue", state}

]


(* ::Subsection:: *)
(*textDocument/publishDiagnostics*)


handleRequest["textDocument/publishDiagnostics", uri_String, state_WorkState] := (
	sendResponse[state["client"], <|
		"method" -> "textDocument/publishDiagnostics",
		"params" -> <|
			"uri" -> uri,
			"diagnostics" -> ToAssociation[DiagnoseDoc[state["openedDocs"][uri]]]
		|>
	|>];
	{"Continue", state}
)


handleRequest["textDocument/clearDiagnostics", uri_String, state_WorkState] := (
	sendResponse[state["client"], <|
		"method" -> "textDocument/publishDiagnostics",
		"params" -> <|
			"uri" -> uri,
			"diagnostics"  -> {}
		|>
	|>];
	{"Continue", state}
)


getScheduleTaskParameter[method:"textDocument/publishDiagnostics", uri_String, state_WorkState] := (
	uri
)


(* ::Subsection:: *)
(*textDocument/hover*)


handleRequest["textDocument/hover", msg_, state_] := With[
	{
		doc = state["openedDocs"][msg["params"]["textDocument"]["uri"]],
		pos = LspPosition[msg["params"]["position"]]
	},

	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> ToAssociation[GetHoverAtPosition[doc, pos]]
	|>];

	{"Continue", state}
]


(* ::Subsection:: *)
(*textDocument/signatureHelp*)


handleRequest[method:"textDocument/signatureHelp", msg_, state_] := (
	state
	// cacheResponse[method, msg]
	// sendCachedResult[method, msg, #]&
 )


cacheResponse[method:"textDocument/signatureHelp", msg_, state_WorkState] := With[
	{
		uri = msg["params"]["textDocument"]["uri"],
		pos = LspPosition[msg["params"]["position"]]

	},

	state
	// ReplaceKey[
		{"caches", method, uri} -> RequestCache[<|
		 	"cachedTime" -> Now,
			"result" -> (
				GetSignatureHelp[state["openedDocs"][uri], pos]
				// ToAssociation
			)
		|>]
	]
]


cacheAvailableQ[method:"textDocument/signatureHelp", msg_, state_WorkState] := Block[
	{
		cachedTime = getCache[method, msg, state]["cachedtime"]
	},

	!MissingQ[cachedTime] && (
		cachedTime
		> DatePlus[Now, {-ServerConfig["requestDelays"][method], "Second"}]
	)
]


getCache[method:"textDocument/signatureHelp", msg_, state_WorkState] := (
	state["caches"][method][msg["params"]["textDocument"]["uri"]]
)


(* ::Subsection:: *)
(*textDocument/completion*)


handleRequest["textDocument/completion", msg_, state_] := Module[
	{
		doc = state["openedDocs"][msg["params"]["textDocument"]["uri"]],
		pos = LspPosition[msg["params"]["position"]]
	},

	msg["params"]["context"]["triggerKind"]
	// Replace[{
		CompletionTriggerKind["Invoked"] :> (
			sendResponse[state["client"], <|
				"id" -> msg["id"],
				"result" -> <|
					"isIncomplete" -> False,
					"items" -> ToAssociation@GetTokenCompletionAtPostion[doc, pos]
				|>
			|>]
		),
		CompletionTriggerKind["TriggerCharacter"] :> (
			sendResponse[state["client"], <|
				"id" -> msg["id"],
				"result" -> <|
					"isIncomplete" -> True,
					"items" -> (
						GetTriggerKeyCompletion[doc, pos]
						// ToAssociation
					)
				|>
			|>]
		),
		CompletionTriggerKind["TriggerForIncompleteCompletions"] :> (
			sendResponse[state["client"], <|
				"id" -> msg["id"],
				"result" -> <|
					"isIncomplete" -> False,
					"items" -> (
						GetIncompleteCompletionAtPosition[doc, pos]
						// ToAssociation
					) 
				|>
			|>];
		)
	}];

	
	{"Continue", state}
]


(* ::Subsection:: *)
(*completionItem/resolve*)


handleRequest["completionItem/resolve", msg_, state_] := With[
	{
		markupKind = (
			state["clientCapabilities"]["textDocument"]["completion"]["completionItem"]["documentationFormat"]
			// First
			// Replace[Except[_?(MemberQ[Values[MarkupKind], #]&)] -> MarkupKind["PlainText"]]
		)
	},

	(* LogDebug @ ("Completion Resolve over token: " <> ToString[token, InputForm]); *)
	
	msg["params"]["data"]["type"]
	// Replace[{
		"Alias" | "LongName" :> (
			sendResponse[state["client"], <|
				"id" -> msg["id"],
				"result" -> msg["params"]
			|>] 
		),
		"Token" :> (
			sendResponse[state["client"], <|
				"id" -> msg["id"],
				"result" -> <|
					msg["params"]
					// Append[
						"documentation" -> <|
							"kind" -> markupKind,
							"value" -> TokenDocumentation[msg["params"]["label"], "usage", "Format" -> markupKind]
						|>
					]
				|>
			|>]
		)
	}];

	addScheduledTask[state, ServerTask[<|
		"type" -> "JustContinue",
		"scheduledTime" -> Now
	|>]]
	// List
	// Prepend["Continue"]
]


(* ::Subsection:: *)
(*textDocument/definition*)


handleRequest["textDocument/definition", msg_, state_] := With[
	{
		doc = state["openedDocs"][msg["params"]["textDocument"]["uri"]],
		pos = LspPosition[msg["params"]["position"]]
	},

	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> ToAssociation@FindDefinitions[doc, pos]
	|>] // AbsoluteTiming // First // LogDebug;

	{"Continue", state}
]


(* ::Subsection:: *)
(*textDocument/references*)


handleRequest["textDocument/references", msg_, state_] := With[
	{
		doc = state["openedDocs"][msg["params"]["textDocument"]["uri"]],
		pos = LspPosition[msg["params"]["position"]],
		includeDeclaration = msg["params"]["context"]["includeDeclaration"]
	},

	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> ToAssociation@FindReferences[doc, pos, "IncludeDeclaration" -> includeDeclaration]
	|>] // AbsoluteTiming // First // LogDebug;

	{"Continue", state}
]


(* ::Subsection:: *)
(*textDocument/documentHighlight*)


handleRequest[method:"textDocument/documentHighlight", msg_, state_WorkState] := With[
	{
		id = msg["id"],
		uri = msg["params"]["textDocument"]["uri"],
		pos = LspPosition[msg["params"]["position"]]
	},

	sendResponse[state["client"], <|
		"id" -> id,
		"result" -> (
			FindDocumentHighlight[state["openedDocs"][uri], pos]
			// ToAssociation
		)
	|>];

	{"Continue", state}
]


getScheduleTaskParameter["textDocument/documentHighlight", msg_, state_WorkState] := (
	msg
)


(* ::Subsection:: *)
(*textDocument/documentSymbol*)


handleRequest[method:"textDocument/documentSymbol", msg_, state_WorkState] := (
	state
	// cacheResponse[method, msg]
	// sendCachedResult[method, msg, #]&
)


cacheResponse[method:"textDocument/documentSymbol", msg_, state_WorkState] := With[
	{
		uri = msg["params"]["textDocument"]["uri"]
	},

	state
	// ReplaceKey[
		{"caches", method, uri} -> RequestCache[<|
		 	"cachedTime" -> Now,
			"result" -> (
				state["openedDocs"][uri]
				// ToDocumentSymbol
				// ToAssociation
			)
		|>]
	]
]


cacheAvailableQ[method:"textDocument/documentSymbol", msg_, state_WorkState] := Block[
	{
		cachedTime = getCache[method, msg, state]["cachedtime"]
	},

	!MissingQ[cachedTime] &&
	!(
		cachedTime <
		state["openedDocs"][
			msg["params"]["textDocument"]["uri"]
		]["lastUpdate"] <
		DateDifference[{ServerConfig["requestDelays"][method], "Second"}, Now]
	)
]


getCache[method:"textDocument/documentSymbol", msg_, state_WorkState] := (
	state["caches"][method][msg["params"]["textDocument"]["uri"]]
)


(* ::Subsection:: *)
(*textDocument/documentColor*)


handleRequest[method:"textDocument/documentColor", msg_, state_WorkState] := (
	state
	// cacheResponse[method, msg]
	// sendCachedResult[method, msg, #]&
)


cacheResponse[method:"textDocument/documentColor", msg_, state_WorkState] := With[
	{
		uri = msg["params"]["textDocument"]["uri"]
	},

	state
	// ReplaceKey[
		{"caches", method, uri} -> RequestCache[<|
		 	"cachedTime" -> Now,
			"result" -> (
				state["openedDocs"][uri]
				// FindDocumentColor
				// ToAssociation
			)
		|>]
	]
]


cacheAvailableQ[method:"textDocument/documentColor", msg_, state_WorkState] := Block[
	{
		cachedTime = getCache[method, msg, state]["cachedTime"]
	},

	!MissingQ[cachedTime] &&
	(state["openedDocs"][
		msg["params"]["textDocument"]["uri"]
	]["lastUpdate"] < cachedTime)
]


getCache[method:"textDocument/documentColor", msg_, state_WorkState] := (
	state["caches"][method][msg["params"]["textDocument"]["uri"]]
)


getScheduleTaskParameter[method:"textDocument/documentColor", msg_, state_WorkState] := (
	msg["params"]["textDocument"]["uri"]
)


(* ::Subsection:: *)
(*textDocument/colorPresentation*)


handleRequest["textDocument/colorPresentation", msg_, state_] := With[
	{
		doc = state["openedDocs"][msg["params"]["textDocument"]["uri"]],
		color = msg["params"]["color"] // LspColor,
		range = msg["params"]["range"] // LspRange
	},

	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"result" -> (
			GetColorPresentation[doc, color, range]
			// ToAssociation
		)
	|>];

	{
		"Continue",
		addScheduledTask[state, ServerTask[<|
			"type" -> "JustContinue",
			"scheduledTime" -> Now
		|>]]
	}

]


(* ::Subsection:: *)
(*Invalid Request*)


handleRequest[_, msg_, state_] := (
	sendResponse[state["client"], <|
		"id" -> msg["id"],
		"error" -> ServerError["MethodNotFound",
			msg
			// ErrorMessageTemplates["MethodNotFound"]
			// LogError
		]
	|>];

	{"Continue", state}
)


(* ::Section:: *)
(*Handle Notifications*)


(* ::Subsection:: *)
(*initialized*)


handleNotification["initialized", msg_, state_] := (
	{
		"Continue",
		state
		// ReplaceKey["initialized" -> True]
		// addScheduledTask[#, ServerTask[<|
			"type" -> "InitialCheck",
			"scheduledTime" -> Now
		|>]]&
	}
)


(* ::Subsection:: *)
(*exit*)


handleNotification["exit", msg_, state_] := (
	{"Stop", state}
)


(* ::Subsection:: *)
(*$/cancelRequest*)


handleNotification["$/cancelRequest", msg_, state_] := With[
	{
		id = msg["params"]["id"]
	},

	FirstPosition[
		state["scheduledTasks"],
		t_ServerTask
		/; (t["id"] == id),
		Missing["NotFound"],
		(*
			levelspec must be {1} to avoid performance bottleneck,
			since params or callback might be complicated
		*)
		{1}
	]
	// Replace[{
		{pos_} :> (
			Part[state["scheduledTasks"], pos]["type"]
			// StringJoin[#, " request is cancelled."]&
			// LogDebug;
			sendResponse[state["client"], <|
				"id" -> id,
				"error" -> ServerError[
					"RequestCancelled",
					"The request is cancelled."
				]
			|>];
			state
			// ReplaceKeyBy["scheduledTasks" -> (Delete[pos])]
		),
		_?MissingQ :> state
	}]
	// List
	// Prepend["Continue"]
]


(* ::Subsection:: *)
(*textSync/didOpen*)


(* This gets the initial state of the text, including document string, version number and the start position of each line in the string.*)
handleNotification["textDocument/didOpen", msg_, state_] := With[
	{
		textDocumentItem = TextDocumentItem[msg["params"]["textDocument"]]
	},

	(* get the association, modify and reinsert *)
	state
	// ReplaceKeyBy["openedDocs" ->
		Append[textDocumentItem["uri"] -> CreateTextDocument[textDocumentItem]]
	]
	// ReplaceKeyBy["caches" -> (Fold[ReplaceKeyBy, #, {
		"textDocument/signatureHelp" ->
			Append[textDocumentItem["uri"] -> RequestCache[<||>]],
		"textDocument/documentSymbol" ->
			Append[textDocumentItem["uri"] -> RequestCache[<||>]],
		"textDocument/documentColor" ->
			Append[textDocumentItem["uri"] -> RequestCache[<||>]],
		"textDocument/codeLens" ->
			Append[textDocumentItem["uri"] -> RequestCache[<||>]],
		"textDocument/publishDiagnostics" ->
			Append[textDocumentItem["uri"] -> <|"scheduledQ" -> False|>]
	 }]&)]
	// handleRequest["textDocument/publishDiagnostics", textDocumentItem["uri"], #]&
]


(* ::Subsection:: *)
(*textSync/didClose*)


handleNotification["textDocument/didClose", msg_, state_] := With[
	{
		uri = msg["params"]["textDocument"]["uri"]
	},

	LogDebug @ ("Close Document " <> uri);

	state
	// ReplaceKeyBy[{"openedDocs"} -> KeyDrop[uri]]
	// ReplaceKeyBy["caches" -> (Fold[ReplaceKeyBy, #, {
		"textDocument/documentSymbol" -> KeyDrop[uri],
		"textDocument/documentColor" -> KeyDrop[uri],
		"textDocument/codeLens" -> KeyDrop[uri]
	}]&)]
	// handleRequest["textDocument/clearDiagnostics", uri, #]&
]


(* ::Subsection:: *)
(*textSync/didChange*)


handleNotification["textDocument/didChange", msg_, state_WorkState] := With[
	{
        doc = msg["params"]["textDocument"],
		uri = msg["params"]["textDocument"]["uri"],
		(* lastUpdate = state["openedDocs"][msg["params"]["textDocument"]["uri"]]["lastUpdate"] *)
		diagScheduledQ = state["caches"]["textDocument/publishDiagnostics"][
			msg["params"]["textDocument"]["uri"]
		]["scheduledQ"]
	},

	(* Because of concurrency, we have to make sure the changed message brings a newer version. *)
	(* With[
		{
			expectedVersion = state["openedDocs"][uri]["version"] + 1
		},

		If[expectedVersion != doc["version"],
			showMessage[
				StringJoin[
					"The version number is not correct.\n",
					"Expect version: ", ToString[expectedVersion], ", ",
					"Actual version: ", ToString[doc["version"]], ".",
					"Please restart the server."
				],
				"Error",
				state
			];
			Return[{"Stop", state}]
		]
	]; *)
	(* newState["openedDocs"][uri]["version"] = doc["version"]; *)

	LogDebug @ ("Change Document " <> uri);
	(* Clean the diagnostics only if lastUpdate time is before delay *)

	state
	// ReplaceKey[{"openedDocs", uri} -> (
		(* Apply all the content changes. *)
		Fold[
			ChangeTextDocument,
			state["openedDocs"][uri],
			ConstructType[msg["params"]["contentChanges"], {__TextDocumentContentChangeEvent}]
		]
		// ReplaceKey["version" -> doc["version"]]
	)]
	// addScheduledTask[#, ServerTask[<|
		"type" -> "JustContinue",
		"scheduledTime" -> Now
	|>]]&
	// If[diagScheduledQ,
		List
		/* Prepend["Continue"],
		ReplaceKey[{"caches", "textDocument/publishDiagnostics", uri, "scheduledQ"} -> True]
		/* (scheduleDelayedRequest["textDocument/publishDiagnostics", uri, #]&)
	]
	(* // If[DatePlus[lastUpdate, {
			ServerConfig["requestDelays"]["textDocument/publishDiagnostics"],
			"Second"
		}] < Now,
		handleRequest["textDocument/clearDiagnostics", uri, #]&
		(* Give diagnostics after delay *)
		/* Last
		/* scheduleDelayedRequest["textDocument/publishDiagnostics", uri, #]&
		/* Last,
	] *)
]


(* ::Subsection:: *)
(*textSync/didSave*)


handleNotification["textDocument/didSave", msg_, state_] := With[
	{
		(* uri = msg["params"]["textDocument"]["uri"] *)
	},
	(* do nothing *)
	{"Continue", state}
]


(* ::Subsection:: *)
(*Invalid Notification*)


handleNotification[_, msg_, state_] := (
	msg
	// ErrorMessageTemplates["MethodNotFound"]
	// LogError;

	{"Continue", state}
)


(* ::Section:: *)
(*Send Message*)


MessageType = <|
	"Error" -> 1,
	"Warning" -> 2,
	"Info" -> 3,
	"Log" -> 4,
	"Debug" -> 4
|>

showMessage[message_String, msgType_String, state_WorkState] := (
	MessageType[msgType]
	// Replace[_?MissingQ :> MessageType["Error"]]
	// LogDebug
	// (type \[Function] 
		sendResponse[state["client"], <|
			"method" -> "window/showMessage", 
			"params" -> <|
				"type" -> type,
				"message" -> message
			|>
		|>]
	)
)

logMessage[message_String, msgType_String, state_WorkState] := (
	MessageType[msgType]
	// Replace[_?MissingQ :> MessageType["Error"]]
	// LogDebug
	// (type \[Function] 
		sendResponse[state["client"], <|
			"method" -> "window/logMessage", 
			"params" -> <|
				"type" -> type,
				"message" -> message
			|>
		|>]
	)
)


(* ::Section:: *)
(*Handle Error*)


ServerError[errorType_String, msg_String] := (
	<|
		"code" -> (
			errorType
			// ErrorCodes
			// Replace[_?MissingQ :> (
				LogError["Invalid error type: " <> errorType];
				ErrorCodes["UnknownErrorCode"]
			)]
		), 
		"message" -> msg
	|>
)


ErrorMessageTemplates = <|
	"MethodNotFound" -> StringTemplate["The requested method `method` is invalid or not implemented"]
|>


(* ::Section:: *)
(*ScheduledTask*)


DeclareType[ServerTask, <|
	"type" -> _String,
	"id" -> _Integer,
	"params" -> _,
	"scheduledTime" -> _DateObject,
	"callback" -> _,
	"duplicateFallback" -> _
|>]


addScheduledTask[state_WorkState, task_ServerTask] := (
	state["scheduledTasks"]
	// Map[Key["scheduledTime"]]
	// FirstPosition[_DateObject?(GreaterThan[task["scheduledTime"]])]
	// Replace[{
		_?MissingQ :> (
			state
			// ReplaceKeyBy["scheduledTasks" -> Append[task]]
		),
		{pos_Integer} :> (
			state
			// ReplaceKeyBy["scheduledTasks" -> Insert[task, pos]]
		)
	}]
)


doNextScheduledTask[state_WorkState] := (
	SelectFirst[state["scheduledTasks"], Key["scheduledTime"] /* LessThan[Now]]
	// Replace[{
		_?MissingQ :> (
			Pause[0.001];
			{"Continue", state}
		),
		task_ServerTask :> Block[
			{
				newState = state // ReplaceKeyBy["scheduledTasks" -> Rest]
			},

			{task["type"], Chop[DateDifference[task["scheduledTime"], Now, "Second"], 10*^-6] // InputForm} // LogInfo;
			task["type"]
			// Replace[{
				method:"textDocument/publishDiagnostics" :> (
					newState
					// If[DatePlus[
						newState["openedDocs"][task["params"]]["lastUpdate"],
						{5, "Second"}] > Now,
						(* Reschedule the task *)
						scheduleDelayedRequest[method, task["params"], #]&,
						ReplaceKey[
							{
								"caches",
								"textDocument/publishDiagnostics",
								task["params"],
								"scheduledQ"
							} -> False
						]
						/* (task["callback"][#, task["params"]]&)
					]
				),
				"InitialCheck" :> (
					newState
					// initialCheck
				),
				"JustContinue" :> {"Continue", newState},
				_ :> (
					FirstPosition[
						newState["scheduledTasks"],
						t_ /; (
							t["type"] == task["type"] &&
							(* same params *)
							t["params"] == task["params"]
						),
						Missing["NotFound"],
						{1}
					] // Replace[{
						(* if there will not be a same task in the future, do it now *)
						_?MissingQ :> If[!MissingQ[task["callback"]],
							(* If the function is time constrained, than the there should not be a lot of lags. *)
							(* TimeConstrained[task["callback"][newState, task["params"]], 0.1, sendResponse[state["client"], <|"id" -> task["params"]["id"], "result" -> <||>|>]], *)
							task["callback"][newState, task["params"]]
							// AbsoluteTiming
							// Apply[(LogInfo[{task["type"], #1}];#2)&],
							sendResponse[newState["client"], <|
								"id" -> task["id"],
								"error" -> ServerError[
									"InternalError",
									"There is no callback function for this scheduled task."
								]
							|>];
							{"Continue", newState}
						],
						(* find a recent duplicate request *)
						_ :> If[!MissingQ[task["duplicateFallback"]],
							(* execute fallback function if applicable *)
							task["duplicateFallback"][newState, task["params"]],
							(* otherwise, return ContentModified error *)
							sendResponse[newState["client"], <|
								"id" -> task["id"],
								"error" -> ServerError[
									"RequestCancelled",
									"There is a more recent duplicate request."
								]
							|>];
							{"Continue", newState}
						]
					}]
				)
			}]
		]
	}]
	// If[WolframLanguageServer`CheckReturnTypeQ,
		Replace[err:Except[{_String, _WorkState}] :> LogError[err]],
		Identity
	]

)


(* ::Section:: *)
(*Misc*)


(* ::Subsection:: *)
(*load config*)


loadConfig[] := Block[
	{
		configPath = FileNameJoin[{WolframLanguageServer`RootDirectory, "config.json"}],
		newConfig
	},

	newConfig = If[FileExistsQ[configPath],
		Join[defaultConfig, Import[configPath, "RawJSON"]],
		defaultConfig
	];
	Export[configPath, newConfig, "RawJSON"];
	newConfig
]


saveConfig[newConfig_Association] := With[
	{
		configPath = FileNameJoin[{WolframLanguageServer`RootDirectory, "config.json"}]
	},

	Export[configPath, newConfig, "RawJSON"];

]


defaultConfig = <|
	"lastCheckForUpgrade" -> DateString[Today]
|>


(* ::Subsection:: *)
(*check upgrades*)


initialCheck[state_WorkState] := (
	checkDependencies[state];
	If[
		DateDifference[
			DateObject[state["config"]["configFileConfig"]["lastCheckForUpgrade"]],
			Today
		] < ServerConfig["updateCheckInterval"],
		logMessage[
			"Upgrade not checked, only a few days after the last check.",
			"Log",
			state
		],
		(* check for upgrade if not checked for more than checkInterval days *)
		checkGitRepo[state];
		(* ReplaceKey[state["config"], "lastCheckForUpgrade" -> DateString[Today]]
		// saveConfig *)
	];
	{"Continue", state}
)

checkGitRepo[state_WorkState] := (
	Check[Needs["GitLink`"],
		showMessage[
			"The GitLink is not installed to the current Wolfram kernel, please check upgrades via git manually.",
			"Info",
			state
		];
		Return[]
	] // Quiet;

	If[!GitLink`GitRepoQ[WolframLanguageServer`RootDirectory],
		showMessage[
			"Wolfram Language Server is not in a git repository, cannot detect upgrades.",
			"Info",
			state
		];
		Return[]
	];

	With[{repo = GitLink`GitOpen[WolframLanguageServer`RootDirectory]},
		If[GitLink`GitProperties[repo, "HeadBranch"] != "master",
			logMessage[
				"Upgrade not checked, the current branch is not 'master'.",
				"Log",
				state
			],
			GitLink`GitAheadBehind[repo, "master", GitLink`GitUpstreamBranch[repo, "master"]]
			// Replace[
				{_, _?Positive} :> (
					showMessage[
						"A new version detected, please close the server and use 'git pull' to upgrade.",
						"Info",
						state
					]
				)
			]
		]
	];
)

If[$VersionNumber >= 12.1,
	pacletInstalledQ[{name_String, version_String}] := (
		PacletObject[name -> version]
		// FailureQ // Not
	),
	pacletInstalledQ[{name_String, version_String}] := (
		PacletManager`PacletInformation[{name, version}]
		// MatchQ[{}] // Not
	)
]

checkDependencies[state_WorkState] := With[
	{
		dependencies = {
			{"CodeParser", "1.0"},
			{"CodeInspector", "1.0"}
		}
	},

	Check[Needs["PacletManager`"],
		showMessage[
			"The PacletManager is not installed to the current Wolfram kernel, please check dependencies manually.",
			"Info",
			state
		];
		Return[]
	];

	dependencies
	// Select[pacletInstalledQ /* Not]
	// Replace[
		missingDeps:Except[{}] :> (
			StringRiffle[missingDeps, ", ", "-"]
			// StringTemplate[StringJoin[
				"These dependencies with correct versions need to be installed or upgraded: ``, ",
				"otherwise the server may malfunction. ",
				"Please see the [Installation](https://github.com/kenkangxgwe/lsp-wl/blob/master/README.md#installation) section for details."
			]]
			// showMessage[#, "Warning", state]&
		)
	]
]


WLServerVersion[] := WolframLanguageServer`Version;


WLServerDebug[] := Print["This is a debug function."];


End[];


EndPackage[];
