open Core
open VR_State
open ClientNormal

let begin_clientrecovery (state : client_state) = 
  let state = client_set_recovering state true in
  let trace = ClientTrace(int_of_index (client_id state), client_n_replicas state, state, 
                          "begin client recovery", "broadcasting client recovery message to replicas") in
  (state, [Communication(Broadcast(ReplicaMessage(ClientRecovery(client_id state)))); 
          Timeout(ClientTimeout(ClientRecoveryTimeout(client_valid_timeout state), int_of_index (client_id state)))], trace)

let on_clientrecovery state c = 
  let trace_event = "client recovery message received" in
  if (status state) <> Normal then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "status is not normal") in
    (state, [], trace)
  else
    let v = view_no state in
    let i = replica_no state in
    let (s, _) = get_client_table_entry state c in
    let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "replying with request number") in
    (state, [Communication(Unicast(ClientMessage(ClientRecoveryResponse(v, s, i)), int_of_index c))], trace)

let on_clientrecoveryresponse (state : client_state) v s i = 
  let trace_event = "client recovery response message received" in
  if not (client_recovering state) then
    (* client is not recovering *)
    let trace = ClientTrace(int_of_index (client_id state), 0, state, trace_event, "already recovered") in
    (state, [], trace)
  else
    let received_clientrecoveryresponse = received_clientrecoveryresponse state i in
    if received_clientrecoveryresponse then
      (* already received a clientrecoveryresponse from this replica *)
      let trace = ClientTrace(int_of_index (client_id state), 0, state, trace_event, "already received response from this replica") in
      (state, [], trace)
    else
      let state = log_clientrecoveryresponse state v s i in
      let q = client_quorum state in
      let no_clientrecoveryresponses = client_no_received_clientrecoveryresponses state in
      if no_clientrecoveryresponses = q then
        let state = client_set_recovering state false in
        send state trace_event
      else
      let trace = ClientTrace(int_of_index (client_id state), 0, state, trace_event, "waiting on more responses") in
        (state, [], trace)
