open Core
open VR_State

let on_request_timeout state v = 
  if (valid_timeout state) = v then
    (* re-send request to all replicas *)
    let (state, op) = previous_operation state in
    (state, [Communication(Broadcast(ReplicaMessage(Request(op, client_id state, client_request_no state)))); 
             Timeout(ClientTimeout(RequestTimeout(client_valid_timeout state), client_id state))])
  else
    (state, [])

let on_clientrecovery_timeout state v = 
  if (valid_timeout state) = v then
    (* re-send recovery message to non-responsive replicas *)
    let indices = waiting_on_clientrecoveryresponses state in
        let multicast = Multicast(ReplicaMessage(ClientRecovery(client_id state)), indices) in
    (state, [Communication(multicast); 
             Timeout(ClientTimeout(ClientRecoveryTimeout(client_valid_timeout state), client_id state))])
  else 
    (state, [])
