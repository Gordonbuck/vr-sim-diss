open Core
open VR_State

let on_request_timeout (state : client_state) v = 
  if (client_valid_timeout state) = v then
    (* re-send request to all replicas *)
    let (state, op) = previous_operation state in
    let trace = ClientTrace(int_of_index (client_id state), client_n_replicas state, state, "request timeout", "broadcasting request") in
    (state, [Communication(Broadcast(ReplicaMessage(Request(op, client_id state, client_request_no state)))); 
             Timeout(ClientTimeout(RequestTimeout(client_valid_timeout state), int_of_index (client_id state)))], trace)
  else
    (state, [], Null)

let on_clientrecovery_timeout (state : client_state) v = 
  if (client_valid_timeout state) = v then
    (* re-send recovery message to non-responsive replicas *)
    let indices = List.map (waiting_on_clientrecoveryresponses state) (fun i -> int_of_index i) in
    let multicast = Multicast(ReplicaMessage(ClientRecovery(client_id state)), indices) in
    let trace = ClientTrace(int_of_index (client_id state), List.length indices, state, "client recovery message timeout", "resending recovery message to nonresponsive replicas") in
    (state, [Communication(multicast); 
             Timeout(ClientTimeout(ClientRecoveryTimeout(client_valid_timeout state), int_of_index (client_id state)))], trace)
  else 
    (state, [], Null)
