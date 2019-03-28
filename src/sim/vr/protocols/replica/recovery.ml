open Core
open VR_State

let begin_recovery state = 
  let state = set_status state Recovering in
  let trace = ReplicaTrace(int_of_index (replica_no state), n_replicas state, state, "began recovering", "broadcast recovery message") in
  (state, [Communication(Broadcast(ReplicaMessage(Recovery(replica_no state, current_recovery_nonce state)))); 
           Timeout(ReplicaTimeout(RecoveryTimeout(valid_timeout state), int_of_index (replica_no state)))], trace)

let on_recovery state i x =
  let trace_event = "received recovery" in
  if (status state) <> Normal then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "not normal status") in
    (state, [], trace)
  else
    let v = view_no state in
    let j = replica_no state in
    if is_primary state then
      let l = log state in
      let n = op_no state in
      let k = commit_no state in
      let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "sending primary recovery response") in
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, Some(l, n, k), j)), int_of_index i))], trace)
    else
      let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "sending recovery response") in
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, None, j)), int_of_index i))], trace)

let on_recoveryresponse state v x opt_p j =
  let trace_event = "received recovery response" in
  if (current_recovery_nonce state) <> x || (status state) <> Recovering then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "for old recovery / not recovering") in
    (state, [], trace)
  else
    let received_recoveryresponse = received_recoveryresponse state j in
    if received_recoveryresponse then
      (* already received a recovery response from this replica *)
      let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "already received recovery response from this replica") in
      (state, [], trace)
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
          let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "successfully recovered") in
          (state, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))], trace)
        | None -> 
          let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "waiting on primary recovery response") in
          (state, [], trace)
      else
        let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "waiting on more recovery responses") in
        (state, [], trace)
