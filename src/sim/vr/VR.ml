open Core
include VR_State
include ClientNormal
include ClientRecovery
include Normal
include Recovery
include StateTransfer
include ViewChange
include ClientTimeouts
include ReplicaTimeouts

let on_replica_message msg state = 
  match msg with
  | Request(op, c, s) -> on_request state op c s
  | Prepare(v, (op, c, s), n, k) -> on_prepare state v (op, c, s) n k
  | PrepareOk(v, n, i) -> on_prepareok state v n i
  | Commit(v, k) -> on_commit state v k
  | StartViewChange(v, i) -> on_startviewchange state v i
  | DoViewChange(v, l, v', n, k, i) -> on_doviewchange state v l v' n k i
  | StartView(v, l, n, k) -> on_startview state v l n k
  | Recovery(i, x) -> on_recovery state i x
  | RecoveryResponse(v, x, opt_p, j) -> on_recoveryresponse state v x opt_p j
  | GetState(v, n', i) -> on_getstate state v n' i
  | NewState(v, l, n, k) -> on_newstate state v l n k
  | ClientRecovery(c) -> on_clientrecovery state c

let on_client_message msg state = 
  match msg with
  | Reply(v, s, res) -> on_reply state v s res
  | ClientRecoveryResponse(v, s, i) -> on_clientrecoveryresponse state v s i

let on_replica_timeout timeout state = 
  match timeout with
  | HeartbeatTimeout(v, n) -> on_heartbeat_timeout state v n
  | PrepareTimeout(v, k) -> on_prepare_timeout state v k
  | PrimaryTimeout(v, n) -> on_primary_timeout state v n
  | StateTransferTimeout(v, n) -> on_statetransfer_timeout state v n
  | StartViewChangeTimeout(v) -> on_startviewchange_timeout state v
  | DoViewChangeTimeout(v) -> on_doviewchange_timeout state v
  | RecoveryTimeout(v) -> on_recovery_timeout state v
  | GetStateTimeout(v, n) -> on_getstate_timeout state v n

let on_client_timeout timeout state =
  match timeout with
  | RequestTimeout(v) -> on_request_timeout state v
  | ClientRecoveryTimeout(v) -> on_clientrecovery_timeout state v

let start_client = start_sending

let recover_replica = begin_recovery
let recover_client = begin_clientrecovery

let replica_is_recovering state = (status state) = Recovering
let client_is_recovering = client_recovering

let compare_logs log1 log2 = 
  let rec compare_logs rlog1 rlog2 = 
    match rlog1 with
    | [] -> Some(log2)
    | r1::rlog1 ->
      match rlog2 with
      | [] -> Some(log1)
      | r2::rlog2 ->
        if r1 = r2 then
          compare_logs rlog1 rlog2
        else
          None in
  compare_logs log1 log2

let check_consistency replicas = 
  let rec inner replicas log1 = 
    match replicas with
    | [] -> true
    | (r::replicas) ->
      let log2 = commited_requests r in
      let larger_log_opt = compare_logs log1 log2 in
      match larger_log_opt with
      | None -> false
      | Some(log) -> inner replicas log in
  inner replicas []

let rec finished_workloads clients = 
  match clients with
  | [] -> true
  | (c::clients) -> (finished_workload c) && (finished_workloads clients)

let string_of_replica_state state = 
  let rec string_of_client_table ct c str = 
    match ct with
    | [] -> String.concat([str; "]"])
    | (s, _)::ct -> string_of_client_table ct (c+1) (String.concat ([(Printf.sprintf "(%i,%i)" c (int_of_index s));str])) in
  let rec string_of_log log str = 
    match log with
    | [] -> String.concat ([str; "]"])
    | (op, c, s)::log -> string_of_log log (String.concat ([(Printf.sprintf "(%i,%i)" (int_of_index c) (int_of_index s));str])) in
  let log = log state in
  let commit_no = commit_no state in
  let ct = client_table state in
  String.concat (["[";(string_of_log log "");" [";(string_of_client_table ct 0 "");Printf.sprintf " commit_no %i" (int_of_index commit_no)])

let string_of_trace trace level = 
  match trace with
  | ReplicaTrace(i, n_packets, state, event, response) -> (
    match level with
    | High -> Printf.sprintf "replica %i; %s; %s; %i packets sent; %s" i event response n_packets (string_of_replica_state state)
    | Medium -> Printf.sprintf "replica %i; %s; %s; %i packets sent" i event response n_packets
    | Low -> Printf.sprintf "replica %i; %s" i event)
  | ClientTrace(i, n_packets, state, event, response) -> (
    match level with
    | High -> Printf.sprintf "client %i; %s; %s; %i packets sent" i event response n_packets
    | Medium -> Printf.sprintf "client %i; %s; %s; %i packets sent" i event response n_packets
    | Low -> Printf.sprintf "client %i; %s" i event)
  | Null -> ""
