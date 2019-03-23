open Core
open VR_State
open ClientNormal

let begin_clientrecovery state = 
  let state = client_set_recovering state true in
  (state [Communication(Broadcast(ReplicaMessage(ClientRecovery(client_id state)))); 
          Timeout(ClientTimeout(ClientRecoveryTimeout(client_valid_timeout state), client_id state))])

let on_clientrecovery state c = 
  if (status state) <> Normal then
    (state, [])
  else
    let v = view_no state in
    let i = replica_no state in
    let (s, _) = get_client_table_entry state c in
    (state, [Communication(Unicast(ClientMessage(ClientRecoveryResponse(v, s, i)), c))])

let on_clientrecoveryresponse state v s i = 
  if not (client_recovering state) then
    (* client is not recovering *)
    (state, [])
  else
    let received_clientrecoveryresponse = received_clientrecoveryresponse state i in
    if received_clientrecoveryresponse then
      (* already received a clientrecoveryresponse from this replica *)
      (state, [])
    else
      let state = log_clientrecoveryresponse state v s i in
      let q = client_quorum state in
      let no_clientrecoveryresponses = client_no_received_clientrecoveryresponses state in
      if no_clientrecoveryresponses = q then
        let state = client_set_recovering state false in
        start_sending state
      else
        (state, [])
