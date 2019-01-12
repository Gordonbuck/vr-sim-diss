open Core
open ClientState
open ReplicaState
open ProtocolEvents
open VR_Utils
open StateTransfer

let on_request state op c s =
  if (is_primary state && state.status = Normal) then
    let cte_opt = List.nth state.client_table c in
    match cte_opt with 
    | None -> (* no client table entry for this client id *) assert(false)
    | Some(cte_s, res_opt) -> 
      if (s = cte_s) then
        (* request already being/been executed, try to return result *)
        match res_opt with
        | None -> (* no result to return *) (state, [])
        | Some(res) -> (* return result for most recent operation *) 
          (state, [Communication(Unicast(ClientMessage(Reply(state.view_no, s, res)), c))])
      else if (s > cte_s) then
        (* begin protocol to execute new request *)
        let op_no = state.op_no + 1 in
        let log = (op, c, s)::state.log in
        let client_table = update_ct state.client_table c s in
        let waiting_prepareoks = 0::state.waiting_prepareoks in
        let communication = Broadcast(ReplicaMessage(Prepare(state.view_no, (op, c, s), op_no, state.commit_no))) in
        let prepare_timeout = ReplicaTimeout(PrepareTimeout(state.valid_timeout, op_no), state.replica_no) in
        let heartbeat_timeout = ReplicaTimeout(HeartbeatTimeout(state.valid_timeout, op_no), state.replica_no) in
        ({state with 
          op_no = op_no;
          log = log;
          client_table = client_table;
          waiting_prepareoks = waiting_prepareoks;
         }, [Communication(communication); Timeout(heartbeat_timeout); Timeout(prepare_timeout)])
      else
        (* drop request *) (state, [])
  else
    (state, [])

let on_prepare state v (op, c, s) n k = 
  if state.status <> Normal || v < state.view_no then
    (state, [])
  else if v > state.view_no then
    later_view state v
  else
    let primary_no = primary_no state.view_no state.configuration in
    let no_primary_comms = state.no_primary_comms + 1 in
    let primary_timeout = ReplicaTimeout(PrimaryTimeout(state.valid_timeout, state.no_primary_comms), state.replica_no) in
    if state.op_no >= n then
      (* already prepared request so re-send prepareok *)
      let communication = Unicast(ReplicaMessage(PrepareOk(state.view_no, state.op_no, state.replica_no)), primary_no) in
      ({state with 
        no_primary_comms = no_primary_comms;
       }, [Communication(communication); Timeout(primary_timeout)])
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
      let events = 
        if op_no > state.op_no then 
          [Communication(Unicast(ReplicaMessage(PrepareOk(state.view_no, op_no, state.replica_no)), primary_no))]
        else 
          [Timeout(ReplicaTimeout(StateTransferTimeout(state.valid_timeout, state.op_no), state.replica_no))] in
      let state = {state with 
                   op_no = op_no;
                   log = log;
                   client_table = client_table;
                   queued_prepares = queued_prepares;
                  } in
      (* tried to prepare, now try to commit *)
      let k = max state.highest_seen_commit_no k in
      let (commit_no, mach, client_table, _) = commit state ((List.length state.log) - 1 - k) in
      ({state with 
        commit_no = commit_no;
        client_table = client_table;
        highest_seen_commit_no = k;
        mach = mach;
        no_primary_comms = no_primary_comms;
       }, Timeout(primary_timeout)::events)

let on_prepareok state v n i = 
  if state.status <> Normal || v < state.view_no then
    (state, [])
  else if v > state.view_no then
    later_view state v
  else
    let casted_prepareok_opt = List.nth state.casted_prepareoks i in
    match casted_prepareok_opt with
    | None -> (* no such replica *) assert(false)
    | Some(casted_prepareok) ->
      if casted_prepareok >= n || state.commit_no >= n then
        (* either already received a prepareok from this replica or already committed operation *)
        (state, [])
      else
        let f = ((List.length state.configuration) / 2) in
        let no_waiting = List.length state.waiting_prepareoks in
        let index = state.commit_no + no_waiting - n in
        let last_casted_index = state.commit_no + no_waiting - casted_prepareok in
        let waiting_prepareoks = List.mapi state.waiting_prepareoks (fun i w -> if i >= index && i < last_casted_index then w+1 else w) in
        let (waiting_prepareoks, commit_until) = process_waiting_prepareoks f waiting_prepareoks in 
        let (commit_no, mach, client_table, replies) = commit state commit_until in
        let comms = List.map replies (fun c -> Communication(c)) in
        let casted_prepareoks = List.mapi state.casted_prepareoks (fun idx m -> if idx = i then n else m) in
        ({state with 
          commit_no = commit_no;
          client_table = client_table;
          waiting_prepareoks = waiting_prepareoks;
          casted_prepareoks = casted_prepareoks;
          mach = mach;
         }, comms)

let on_commit state v k = 
  if state.status <> Normal || v < state.view_no then
    (state, [])
  else if v > state.view_no then
    later_view state v
  else
    let no_primary_comms = state.no_primary_comms + 1 in
    let k = max state.highest_seen_commit_no k in
    let (commit_no, mach, client_table, _) = commit state ((List.length state.log) - 1 - k) in
    ({state with 
      commit_no = commit_no;
      client_table = client_table;
      highest_seen_commit_no = k;
      mach = mach;
      no_primary_comms = no_primary_comms;
     }, [Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, no_primary_comms), state.replica_no))])
