open Core
open ClientState
open ReplicaState
open ProtocolEvents
open VR_Utils

let begin_recovery state = 
  let status = Recovering in
  let i = state.replica_no in
  let x = state.recovery_nonce + 1 in
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    status = status;
    recovery_nonce = x;
    valid_timeout = valid_timeout;
   }, [Communication(Broadcast(ReplicaMessage(Recovery(i, x)))); 
       Timeout(ReplicaTimeout(RecoveryTimeout(valid_timeout), state.replica_no))])

let on_recovery state i x =
  if state.status <> Normal then
    (state, [])
  else
    let v = state.view_no in
    let j = state.replica_no in
    if is_primary state then
      let l = state.log in
      let n = state.op_no in
      let k = state.commit_no in
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, Some(l, n, k), j)), i))])
    else
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, None, j)), i))])

let on_recoveryresponse state v x opt_p j = 
  if state.recovery_nonce <> x || state.status <> Recovering then
    (state, [])
  else
    let received_recoveryresponse_opt = List.nth state.received_recoveryresponses j in
    match received_recoveryresponse_opt with
    | None -> (* no such replica *) assert(false)
    | Some(received_recoveryresponse) ->
      if received_recoveryresponse then
        (* already received a recovery response from this replica *)
        (state, [])
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
            let (_, mach, client_table, _) = commit state ((List.length state.log) - 1 - k) in
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
             }, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout, 0), state.replica_no))])
          | None -> ({state with 
                      view_no = view_no;
                      no_recoveryresponses = no_recoveryresponses;
                      received_recoveryresponses = received_recoveryresponses;
                      primary_recoveryresponse = primary_recoveryresponse;
                     }, [])
        else
          ({state with 
            view_no = view_no;
            no_recoveryresponses = no_recoveryresponses;
            received_recoveryresponses = received_recoveryresponses;
            primary_recoveryresponse = primary_recoveryresponse;
           }, [])
