open Core
open State
open Comms
open Timeouts
open VR_utils

module type Protocol_type = sig
  type replica_state
  type client_state
  type replica_message
  type client_message
  type message = ReplicaMessage of replica_message | ClientMessage of client_message
  type communication = Unicast of message * int |  Broadcast of message | MultiComm of communication list
  type replica_timeout
  type client_timeout
  type timeout = ReplicaTimeout of replica_timeout | ClientTimeout of client_timeout
  val on_replica_message: replica_state -> replica_message -> replica_state * communication option * timeout list
  val on_client_message: client_state -> client_message -> client_state * communication option * timeout list
  val on_replica_timeout: replica_state -> replica_timeout -> replica_state * communication option * timeout list
  val on_client_timeout: client_state -> client_timeout -> client_state * communication option * timeout list
end

  (* normal operation protocol implementation *)

let on_request state op c s =
  if (is_primary state) then
    let cte_opt = List.nth state.client_table c in
    match cte_opt with 
    | None -> (* no client table entry for this client id *) assert(false)
    | Some(cte_s, res_opt) -> 
      if (cte_s = s) then
        (* request already being/been executed, try to return result *)
        match res_opt with
        | None -> (* no result to return *) (state, None, [])
        | Some(res) -> (* return result for most recent operation *) 
          (state, Some(Unicast(ClientMessage(Reply(state.view_no, s, res)), c)), [])
      else if (cte_s > s) then
        (* begin protocol to execute new request *)
        let op_no = state.op_no + 1 in
        let log = (op, c, s)::state.log in
        let client_table = update_ct state.client_table c s in
        let waiting_prepareoks = 0::state.waiting_prepareoks in
        let prepare_timeout = PrepareTimeout(state.valid_timeout, op_no) in
        let heartbeat_timeout = HeartbeatTimeout(state.valid_timeout, op_no) in
        ({state with 
          op_no = op_no;
          log = log;
          client_table = client_table;
          waiting_prepareoks = waiting_prepareoks;
         }, Some(Broadcast(ReplicaMessage(Prepare(state.view_no, (op, c, s), op_no, state.commit_no)))), 
         [ReplicaTimeout(state.replica_no, heartbeat_timeout); ReplicaTimeout(state.replica_no, prepare_timeout)])
      else
        (* drop request *) (state, None, [])
  else
    (state, None, [])

let on_prepare state v (op, c, s) n k = 
  let state = {state with no_primary_comms = state.no_primary_comms+1;} in
  let primary_no = primary_no state.view_no state.configuration in
  let primary_timeout = PrimaryTimeout(state.valid_timeout, state.no_primary_comms) in
  if state.op_no >= n then
    (* already prepared request so re-send prepareok *)
    (state, Some(Unicast(ReplicaMessage(PrepareOk(state.view_no, state.op_no, state.replica_no)), primary_no)),
     [ReplicaTimeout(state.replica_no, primary_timeout)])
  else
    (* try to prepare request, may not be able to without earlier requests, and send prepareok if prepared anything *)
    let no_queued = List.length state.queued_prepares in
    let index = state.op_no + no_queued - n in
    let queued_prepares = 
      if (index >= 0) then 
        List.mapi state.queued_prepares (fun i req_opt -> if i = index then Some((op, c, s)) else req_opt)
      else 
        Some((op, c, s))::(add_nones state.queued_prepares (-(index + 1))) in    
    let (queued_prepares, prepared) = process_queued_prepares queued_prepares in
    let op_no = state.op_no + List.length prepared in
    let log = List.append prepared state.log in
    let client_table = update_ct_reqs state.client_table (List.rev prepared) in
    let comm_opt = 
      if op_no > state.op_no then Some(Unicast(ReplicaMessage(PrepareOk(state.view_no, op_no, state.replica_no)), primary_no)) 
      else None in
    let statetransfer_timeout_l = 
      if op_no > state.op_no then [] else [ReplicaTimeout(state.replica_no, StateTransferTimeout(state.valid_timeout, state.op_no))] in
    ({state with 
      op_no = op_no;
      log = log;
      client_table = client_table;
      queued_prepares = queued_prepares;
     }, comm_opt, 
     (ReplicaTimeout(state.replica_no, primary_timeout))::statetransfer_timeout_l)

let on_prepareok state v n i = 
  let casted_prepareok_opt = List.nth state.casted_prepareoks i in
  match casted_prepareok_opt with
  | None -> (* no such replica *) assert(false)
  | Some(casted_prepareok) ->
    if casted_prepareok >= n || state.commit_no >= n then
      (* either already received a prepareok from this replica or already committed operation *)
      (state, None, [])
    else
      let f = ((List.length state.configuration) / 2) in
      let no_waiting = List.length state.waiting_prepareoks in
      let index = state.commit_no + no_waiting - n in
      let last_casted_index = state.commit_no + no_waiting - casted_prepareok in
      let waiting_prepareoks = List.mapi state.waiting_prepareoks (fun i w -> if i >= index && i < last_casted_index then w+1 else w) in
      let (waiting_prepareoks, commit_until) = process_waiting_prepareoks f waiting_prepareoks in 
      let last_committed_index = (List.length state.log) - 1 - state.commit_no in
      let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
      let (mach, client_table, replies) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
      let commit_no = state.commit_no + (List.length to_commit) in
      let comm_opt = if List.length replies > 0 then Some(MultiComm(replies)) else None in
      let casted_prepareoks = List.mapi state.casted_prepareoks (fun idx m -> if idx = i then n else m) in
      ({state with 
        commit_no = commit_no;
        client_table = client_table;
        waiting_prepareoks = waiting_prepareoks;
        casted_prepareoks = casted_prepareoks;
        mach = mach;
       }, comm_opt, [])

let on_commit state v k = 
  let state = {state with no_primary_comms = state.no_primary_comms+1;} in
  let k = max state.highest_seen_commit_no k in
  let commit_until = (List.length state.log) - 1 - k in
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
  let commit_no = state.commit_no + (List.length to_commit) in
  ({state with 
    commit_no = commit_no;
    client_table = client_table;
    highest_seen_commit_no = k;
    mach = mach;
   }, None, 
   [ReplicaTimeout(state.replica_no, PrimaryTimeout(state.valid_timeout, state.no_primary_comms))])

  (* view change protocol implementation *)

let notice_viewchange state = 
  let view_no = state.view_no + 1 in 
  let status = ViewChange in
  let no_startviewchanges = 0 in
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    view_no = view_no;
    status = status;
    no_startviewchanges = no_startviewchanges;
    received_startviewchanges = received_startviewchanges;
    valid_timeout = valid_timeout;
   }, Some(Broadcast(ReplicaMessage(StartViewChange(view_no, state.replica_no)))),
   [ReplicaTimeout(state.replica_no, StartViewChangeTimeout(valid_timeout))])

let on_startviewchange state v i =
  let received_startviewchange_opt = List.nth state.received_startviewchanges i in
  match received_startviewchange_opt with
  | None -> (* no replica for this index *) assert(false)
  | Some(received_startviewchange) ->
    if received_startviewchange then
      (* already received a startviewchange from this replica*)
      (state, None, [])
    else
      let f = ((List.length state.configuration) / 2) in
      let no_startviewchanges = state.no_startviewchanges + 1 in
      let primary_no = primary_no state.view_no state.configuration in
      let comm_opt = 
        if (no_startviewchanges = f) then 
          Some(Unicast(ReplicaMessage(DoViewChange(
              state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no)), primary_no))
        else
          None in
      let received_startviewchanges = List.mapi state.received_startviewchanges (fun idx b -> if idx = i then true else b) in
      let doviewchange_timeout_l = 
        if (no_startviewchanges = f) then
          [ReplicaTimeout(state.replica_no, DoViewChangeTimeout(state.valid_timeout)); 
           ReplicaTimeout(state.replica_no, PrimaryTimeout(state.valid_timeout, state.no_primary_comms))]
        else [] in
      ({state with 
        no_startviewchanges = no_startviewchanges;
        received_startviewchanges = received_startviewchanges;
       }, comm_opt, doviewchange_timeout_l)

let on_doviewchange state v l v' n k i =
  if state.status = Normal then
    (* recovered, re-send startview message *)
    (state, Some(Unicast(ReplicaMessage(StartView(state.view_no, state.log, state.op_no, state.commit_no)), i)), [])
  else
    let received_doviewchange = received_doviewchange state.doviewchanges i in
    if received_doviewchange then
      (* already received a doviewchange message from this replica *)
        (state, None, [])
    else  
      let f = ((List.length state.configuration) / 2) in
      let no_doviewchanges = (List.length state.doviewchanges) + 1 in
      let doviewchanges = (v, l, v', n, k, i)::state.doviewchanges in
      if (no_doviewchanges = f + 1) then
        let status = Normal in 
        let view_no = v in
        let (log, last_normal_view_no, op_no, commit_no) = process_doviewchanges doviewchanges in
        let last_committed_index = (List.length state.log) - 1 - state.commit_no in
        let commit_until = (List.length state.log) - 1 - commit_no in
        let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
        let (mach, client_table, replies) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
        let waiting_prepareoks = List.init (op_no - commit_no) (fun _ -> 0) in
        let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
        let casted_prepareoks = List.map state.casted_prepareoks (fun _ -> commit_no) in
        let valid_timeout = state.valid_timeout + 1 in
        ({state with 
          view_no = view_no;
          status = status;
          op_no = op_no;
          log = log;
          commit_no = commit_no;
          client_table = client_table;
          queued_prepares = [];
          waiting_prepareoks = waiting_prepareoks;
          casted_prepareoks = casted_prepareoks;
          highest_seen_commit_no = commit_no;
          no_startviewchanges = 0;
          received_startviewchanges = received_startviewchanges;
          doviewchanges = [];
          last_normal_view_no = view_no;
          mach = mach;
          valid_timeout = valid_timeout;
          no_primary_comms = 0;
         }, Some(MultiComm(Broadcast(ReplicaMessage(StartView(view_no, log, op_no, commit_no)))::replies)),
         [ReplicaTimeout(state.replica_no, HeartbeatTimeout(state.replica_no, op_no))])
      else 
        ({state with 
          doviewchanges = doviewchanges;
         }, None, [])

let on_startview state v l n k = 
  let view_no = v in
  let log = l in
  let op_no = n in
  let status = Normal in 
  let commit_no = k in
  let last_committed_index = (List.length state.log) - 1 - state.commit_no in
  let commit_until = (List.length state.log) - 1 - commit_no in
  let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
  let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
  let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
  let primary_no = primary_no view_no state.configuration in
  let comm_opt = 
    if (commit_no < op_no) then
      Some(Unicast(ReplicaMessage(PrepareOk(view_no, op_no, state.replica_no)), primary_no))
    else
      None in
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    view_no = view_no;
    status = status;
    op_no = op_no;
    log = log;
    commit_no = commit_no;
    client_table = client_table;
    queued_prepares = [];
    waiting_prepareoks = [];
    highest_seen_commit_no = commit_no;
    no_startviewchanges = 0;
    received_startviewchanges = received_startviewchanges;
    doviewchanges = [];
    last_normal_view_no = view_no;
    mach = mach;
    valid_timeout = valid_timeout;
    no_primary_comms = 0;
   }, comm_opt, [ReplicaTimeout(state.replica_no, PrimaryTimeout(valid_timeout, 0))])

  (* recovery protocol implementation *)

let begin_recovery state = 
  let status = Recovering in
  let i = state.replica_no in
  let x = state.recovery_nonce + 1 in
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    status = status;
    recovery_nonce = x;
    valid_timeout = valid_timeout;
   }, Some(Broadcast(ReplicaMessage(Recovery(i, x)))),
   [ReplicaTimeout(state.replica_no, RecoveryTimeout(valid_timeout))])

let on_recovery state i x =
  let v = state.view_no in
  let j = state.replica_no in
  if is_primary state then
    let l = state.log in
    let n = state.op_no in
    let k = state.commit_no in
    (state, Some(Unicast(ReplicaMessage(RecoveryResponse(v, x, Some(l, n, k), j)), i)), [])
  else
    (state, Some(Unicast(ReplicaMessage(RecoveryResponse(v, x, None, j)), i)), [])

let on_recoveryresponse state v x opt_p j = 
  if state.recovery_nonce <> x then
    (state, None, [])
  else
    let received_recoveryresponse_opt = List.nth state.received_recoveryresponses j in
    match received_recoveryresponse_opt with
    | None -> (* no such replica *) assert(false)
    | Some(received_recoveryresponse) ->
      if received_recoveryresponse then
        (* already received a recovery response from this replica *)
        (state, None, [])
      else
        let no_recoveryresponses = state.no_recoveryresponses + 1 in
        let received_recoveryresponses = List.mapi state.received_recoveryresponses (fun i b -> if i = j then true else b) in
        let primary_recoveryresponse = 
          match opt_p with
          | Some(l, n, k) -> if v < state.view_no then state.primary_recoveryresponse else Some(v, x, l, n, k, j)
          | None -> if v > state.view_no then None else state.primary_recoveryresponse in
        let view_no = max v state.view_no in
        let f = ((List.length state.configuration) / 2) in
        if no_recoveryresponses >= f+1 then
          match state.primary_recoveryresponse with
          | Some(v, x, l, n, k, j) ->
            let log = l in
            let op_no = n in
            let status = Normal in 
            let commit_no = k in
            let last_committed_index = (List.length state.log) - 1 - state.commit_no in
            let commit_until = (List.length state.log) - 1 - commit_no in
            let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
            let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
            let received_recoveryresponses = List.map state.received_recoveryresponses (fun _ -> false) in
            let valid_timeout = state.valid_timeout + 1 in
            ({state with 
              view_no = view_no;
              log = log;
              op_no = op_no;
              status = status;
              commit_no = k;
              client_table = client_table;
              no_recoveryresponses = 0;
              received_recoveryresponses = received_recoveryresponses;
              primary_recoveryresponse = None;
              mach = mach;
              valid_timeout = valid_timeout;
              no_primary_comms = 0;
             }, None, [ReplicaTimeout(state.replica_no, PrimaryTimeout(valid_timeout, 0))])
          | None -> ({state with 
                      view_no = view_no;
                      no_recoveryresponses = no_recoveryresponses;
                      received_recoveryresponses = received_recoveryresponses;
                      primary_recoveryresponse = primary_recoveryresponse;
                     }, None, [])
        else
          ({state with 
            view_no = view_no;
            no_recoveryresponses = no_recoveryresponses;
            received_recoveryresponses = received_recoveryresponses;
            primary_recoveryresponse = primary_recoveryresponse;
           }, None, [])
      
  (* state transfer protocol implementation *)

let begin_statetransfer state = 
  let primary_no = primary_no state.view_no state.configuration in
  (state, Some(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no)),
   [ReplicaTimeout(state.replica_no, GetStateTimeout(state.valid_timeout, state.op_no))])

let later_view state v = 
  let op_no = state.commit_no in
  let remove_until = state.op_no - state.commit_no in
  let log = List.drop state.log remove_until in
  let valid_timeout = state.valid_timeout + 1 in
  begin_statetransfer {state with 
    view_no = v;
    op_no = op_no;
    log = log;
    valid_timeout = valid_timeout;
   }

let on_getstate state v n' i = 
  let take_until = state.op_no - n' in
  let log = List.take state.log take_until in
  (state, Some(Unicast(ReplicaMessage(NewState(state.view_no, log, state.op_no, state.commit_no)), i)), [])

let on_newstate state v l n k =
  if n <= state.op_no then
    (* replica has already got this state *)
    (state, None, [])
  else
    let log = List.append l state.log in
    let commit_until = (List.length log) - 1 - k in
    let last_committed_index = (List.length log) - 1 - state.commit_no in
    let to_commit = List.filteri log (fun i _ -> i < last_committed_index && i >= commit_until) in
    let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
    ({state with 
      op_no = n;
      log = log;
      commit_no = k;
      client_table = client_table;
      queued_prepares = [];
      waiting_prepareoks = [];
      mach = mach;
     }, None, [ReplicaTimeout(state.valid_timeout, PrimaryTimeout(state.valid_timeout, n))])

(* client-side normal protocol implementation *)

let start_sending (state : client_state) = 
  let op_opt = List.nth state.operations_to_do state.next_op_index in
  let next_op_index = state.next_op_index + 1 in
  let primary_no = primary_no state.view_no state.configuration in
  let request_no = state.request_no + 1 in
  let state = {state with 
               request_no = request_no;
               next_op_index = next_op_index;
              } in
  match op_opt with
  | None -> (* no operations left *) (state, None, [])
  | Some(op) -> (* send next request *) (state, 
                                         Some(Unicast(ReplicaMessage(Request(op, state.client_id, request_no)), primary_no)),
                                         [ClientTimeout(state.client_id, RequestTimeout(state.valid_timeout))])

let on_reply state v s res = 
  if s < state.request_no || state.recovering then
    (* already received this reply or recovering so cant proceed *)
    (state, None, [])
  else
    let valid_timeout = state.valid_timeout + 1 in
    let state = {state with valid_timeout = valid_timeout;} in
    start_sending state

  (* client recovery protocol implementation *)

let begin_clientrecovery (state : client_state) = 
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    recovering = true;
    valid_timeout = valid_timeout;
   }, Some(Broadcast(ReplicaMessage(ClientRecovery(state.client_id)))),
   [ClientTimeout(state.client_id, ClientRecoveryTimeout(valid_timeout))])

let on_clientrecovery state c = 
  let v = state.view_no in
  let i = state.replica_no in
  let opt = List.nth state.client_table c in
  match opt with 
  | None -> assert(false)
  | Some(s, res) ->
    (state, Some(Unicast(ClientMessage(ClientRecoveryResponse(v, s, i)), c)), [])

let on_clientrecoveryresponse (state : client_state) v s i = 
  if not state.recovering then
    (* client is not recovering *)
    (state, None, [])
  else
    let received_clientrecoveryresponse_opt = List.nth state.received_clientrecoveryresponses i in
    match received_clientrecoveryresponse_opt with
    | None -> (* no such replica exists *) assert(false)
    | Some(received_clientrecoveryresponse) -> 
      if received_clientrecoveryresponse then
        (* already received a clientrecoveryresponse from this replica *)
        (state, None, [])
      else
        let f = ((List.length state.configuration) / 2) in
        let no_clientrecoveryresponses = state.no_clientrecoveryresponses + 1 in
        let request_no = max s state.request_no in
        let view_no = max v state.view_no in
        if no_clientrecoveryresponses = f+1 then
          let received_clientrecoveryresponses = List.map state.received_clientrecoveryresponses (fun _ -> false) in
          let valid_timeout = state.valid_timeout + 1 in
          let state = {state with 
                       view_no = view_no;
                       request_no = request_no + 1;
                       recovering = false;
                       no_clientrecoveryresponses = 0;
                       received_clientrecoveryresponses = received_clientrecoveryresponses;
                       valid_timeout = valid_timeout;
                      } in
          start_sending state
        else
          let received_clientrecoveryresponses = 
            List.mapi state.received_clientrecoveryresponses (fun idx b -> if idx = i then true else b) in
          ({state with 
            view_no = view_no;
            request_no = request_no;
            no_clientrecoveryresponses = no_clientrecoveryresponses;
            received_clientrecoveryresponses = received_clientrecoveryresponses;
           }, None, [])

  (* replica timeouts *)

let on_heartbeat_timeout state n = 
  if state.op_no = n then
    (* send commit message as heartbeat *)
    (state, Some(Broadcast(ReplicaMessage(Commit(state.view_no, state.commit_no)))),
     [ReplicaTimeout(state.replica_no, HeartbeatTimeout(state.valid_timeout, state.op_no))])
  else
    (state, None, [])

let on_prepare_timeout state k = 
  if state.commit_no < k then
    (* havent committed the operation yet *)
    let req_opt = List.nth state.log k in
    match req_opt with
    | None -> (* no such request in log, should have been caught by valid timer tag *) assert(false)
    | Some(req) ->
      (* send prepare message to non-responsive replicas *)
      let received_prepareoks = List.map state.casted_prepareoks (fun m -> m >= k) in
      let comms = map_falses received_prepareoks 
          (fun i -> Unicast(ReplicaMessage(Prepare(state.view_no, req, k, state.commit_no)), i)) in
      let prepare_timeout = PrepareTimeout(state.valid_timeout, k) in
      (state, Some(MultiComm(comms)), [ReplicaTimeout(state.valid_timeout, prepare_timeout)])
  else
    (state, None, [])

let on_primary_timeout state n = 
  if state.no_primary_comms = n then
    (* no communication from primary since last timeout check, start viewchange *)
    notice_viewchange state
  else
    (state, None, [])

let on_statetransfer_timeout state n = 
  if state.op_no <= n then
    (* haven't received missing prepare message, initiate state transfer *)
    begin_statetransfer state
  else
    (state, None, [])

let on_startviewchange_timeout state = 
  (* re-send startviewchange messages to non-responsive replicas *)
  let comms = map_falses state.received_startviewchanges 
      (fun i -> Unicast(ReplicaMessage(StartViewChange(state.view_no, state.replica_no)), i)) in
  (state, Some(MultiComm(comms)), [ReplicaTimeout(state.replica_no, StartViewChangeTimeout(state.valid_timeout))])

let on_doviewchange_timeout state = 
  (* re-send doviewchange message to primary *)
  let primary_no = primary_no state.view_no state.configuration in
  (state, Some(Unicast(ReplicaMessage(DoViewChange(
       state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no)), primary_no)),
   [ReplicaTimeout(state.replica_no, DoViewChangeTimeout(state.valid_timeout))])

let on_recovery_timeout state = 
  (* re-send recovery messages to non-responsive replicas *)
  let comms = map_falses state.received_recoveryresponses 
      (fun i -> Unicast(ReplicaMessage(Recovery(state.replica_no, state.recovery_nonce)), i)) in
  (state, Some(MultiComm(comms)), [ReplicaTimeout(state.replica_no, RecoveryTimeout(state.valid_timeout))])

let on_getstate_timeout state n =
  if state.op_no <= n then
    (* havent updated log since request for more state, re-send request *)
    let primary_no = primary_no state.view_no state.configuration in
    (state, Some(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no)),
     [ReplicaTimeout(state.replica_no, GetStateTimeout(state.valid_timeout, state.op_no))])
  else
    (state, None, [])

  (* client timeouts *)

let on_request_timeout (state : client_state) = 
  (* re-send request to all replicas *)
  let op_opt = List.nth state.operations_to_do (state.next_op_index - 1) in
  match op_opt with
  | None -> (* no request to re-send *) assert(false)
  | Some(op) ->
    (* re-send request to all replicas *)
    let valid_timeout = state.valid_timeout + 1 in
    ({state with 
      valid_timeout = valid_timeout;
     }, Some(Broadcast(ReplicaMessage(Request(op, state.client_id, state.request_no)))), 
     [ClientTimeout(state.client_id, RequestTimeout(valid_timeout))])

let on_clientrecovery_timeout (state : client_state) = 
  (* re-send recovery message to non-responsive replicas *)
  let comms = map_falses state.received_clientrecoveryresponses 
      (fun i -> Unicast(ReplicaMessage(ClientRecovery(state.client_id)), i)) in
  (state, Some(MultiComm(comms)), [ClientTimeout(state.client_id, ClientRecoveryTimeout(state.valid_timeout))])

  (* tying protocol implementation together *)

let on_replica_message state msg = 
  (* perform status and view number checks here *)
  match msg with
  
  | Request(op, c, s) ->
    if state.status = Normal then
      on_request state op c s
    else 
      (state, None, [])

  | Prepare(v, m, n, k) -> 
    if state.status <> Normal || v < state.view_no then
      (state, None, [])
    else if v > state.view_no then
      later_view state v
    else
      let (state, comm_opt, t1s) = on_prepare state v m n k in
      let (state, _, t2s) = on_commit state v k in
      (state, comm_opt, List.append t2s t1s)

  | PrepareOk(v, n, i) -> 
    if state.status <> Normal || v < state.view_no then
      (state, None, [])
    else if v > state.view_no then
      later_view state v
    else
      on_prepareok state v n i 

  | Commit(v, k) -> 
    if state.status <> Normal || v < state.view_no then
      (state, None, [])
    else if v > state.view_no then
      later_view state v
    else
      on_commit state v k

  | StartViewChange(v, i) -> 
    if state.status = Recovering || v < state.view_no then
      (state, None, [])
    else if v > state.view_no then
      notice_viewchange state
    else
      on_startviewchange state v i

  | DoViewChange(v, l, v', n, k, i) -> 
    if state.status = Recovering || v < state.view_no then
      (state, None, [])
    else if v > state.view_no then
      notice_viewchange state
    else
      on_doviewchange state v l v' n k i

  | StartView(v, l, n, k) -> 
    if state.status = Recovering || v < state.view_no then
      (state, None, [])
    else
      on_startview state v l n k

  | Recovery(i, x) -> 
    if state.status <> Normal then
      (state, None, [])
    else
      on_recovery state i x

  | RecoveryResponse(v, x, opt, j) -> 
    if state.status <> Recovering then
      (state, None, [])
    else
      on_recoveryresponse state v x opt j

  | ClientRecovery(c) -> 
    on_clientrecovery state c

  | GetState(v, n', i) -> 
    if state.status <> Normal || state.view_no <> v then
      (state, None, [])
    else
      on_getstate state v n' i

  | NewState(v, l, n, k) -> 
    if state.status <> Normal || state.view_no <> v then
      (state, None, [])
    else
      on_newstate state v l n k

let on_client_message state msg =
  match msg with 
  
  | Reply(v, s, res) -> 
    on_reply state v s res

  | ClientRecoveryResponse(v, s, i) -> 
    on_clientrecoveryresponse state v s i

let on_replica_timeout state timeout = 
  match timeout with

  | HeartbeatTimeout(v, n) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_heartbeat_timeout state n

  | PrepareTimeout(v, k) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_prepare_timeout state k

  | PrimaryTimeout(v, n) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_primary_timeout state n

  | StateTransferTimeout(v, n) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_statetransfer_timeout state n

  | StartViewChangeTimeout(v) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_startviewchange_timeout state

  | DoViewChangeTimeout(v) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_doviewchange_timeout state

  | RecoveryTimeout(v) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_recovery_timeout state

  | GetStateTimeout(v, n) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_getstate_timeout state n

let on_client_timeout (state : client_state) timeout =
  match timeout with

  | RequestTimeout(v) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_request_timeout state
    
  | ClientRecoveryTimeout(v) ->
    if state.valid_timeout <> v then 
      (state, None, [])
    else 
      on_clientrecovery_timeout state
















