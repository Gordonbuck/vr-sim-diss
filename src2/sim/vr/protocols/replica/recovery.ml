open Core
open VR_State

let begin_recovery state = 
  let state = set_status state Recovery in
  (state, [Communication(Broadcast(ReplicaMessage(Recovery(replica_no state, current_recovery_nonce state)))); 
           Timeout(ReplicaTimeout(RecoveryTimeout(valid_timeout state), replica_no state))])

let on_recovery state i x =
  if (status state) <> Normal then
    (state, [])
  else
    let v = view_no state in
    let j = replica_no state in
    if is_primary state then
      let l = log state in
      let n = op_no state in
      let k = commit_no state in
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, Some(l, n, k), j)), i))])
    else
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, None, j)), i))])

let on_recoveryresponse state v x opt_p j =
  if (current_recovery_nonce state) <> x || (status state) <> Recovering then
    (state, [])
  else
    let received_recoveryresponse = received_recoveryresponse state j in
    if received_recoveryresponse then
      (* already received a recovery response from this replica *)
      (state, [])
    else
      let state = log_recoveryresponse state v x opt_p j in
      let q = quorum state in
      let no_recoveryresponses = no_received_recoveryresponses state in
      if no_recoveryresponses >= q then
        match (primary_recoveryresponse state) with
        | Some(_, _, l, n, k, _) ->
          let state = set_log state l in
          let state =  set_op_no state n in
          let state = set_status state Normal in
          let state = become_replica state in
          let (state, _) = commit state k in
          (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), replica_no state))])
        | None -> (state, [])
      else
        (state, [])
