open Core
open ClientState
open ReplicaState
open VR_Events
open VR_Utils

let on_request_timeout (state : client_state) v = 
  if state.valid_timeout = v then
    (* re-send request to all replicas *)
    let op_opt = List.nth state.operations_to_do (state.next_op_index - 1) in
    match op_opt with
    | None -> (* no request to re-send *) assert(false)
    | Some(op) ->
      (* re-send request to all replicas *)
      let valid_timeout = state.valid_timeout + 1 in
      ({state with 
        valid_timeout = valid_timeout;
       }, [Communication(Broadcast(ReplicaMessage(Request(op, state.client_id, state.request_no)))); 
           Timeout(ClientTimeout(RequestTimeout(valid_timeout), state.client_id))])
  else
    (state, [])

let on_clientrecovery_timeout (state : client_state) v = 
  if state.valid_timeout = v then
    (* re-send recovery message to non-responsive replicas *)
    let indices = map_falses state.received_clientrecoveryresponses (fun i -> i) in
    let multicast = Multicast(ReplicaMessage(ClientRecovery(state.client_id)), indices) in
    (state, [Communication(multicast); 
             Timeout(ClientTimeout(ClientRecoveryTimeout(state.valid_timeout), state.client_id))])
  else 
    (state, [])
