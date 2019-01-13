open Core
open ClientState
open ReplicaState
open VR_Events
open VR_Utils
open ClientNormal

let begin_clientrecovery (state : client_state) = 
  let valid_timeout = state.valid_timeout + 1 in
  ({state with 
    recovering = true;
    valid_timeout = valid_timeout;
   }, [Communication(Broadcast(ReplicaMessage(ClientRecovery(state.client_id)))); 
       Timeout(ClientTimeout(ClientRecoveryTimeout(valid_timeout), state.client_id))])

let on_clientrecovery state c = 
  if state.status <> Normal then
    (state, [])
  else
    let v = state.view_no in
    let i = state.replica_no in
    let opt = List.nth state.client_table c in
    match opt with 
    | None -> assert(false)
    | Some(s, res) ->
      (state, [Communication(Unicast(ClientMessage(ClientRecoveryResponse(v, s, i)), c))])

let on_clientrecoveryresponse (state : client_state) v s i = 
  if not state.recovering then
    (* client is not recovering *)
    (state, [])
  else
    let received_clientrecoveryresponse_opt = List.nth state.received_clientrecoveryresponses i in
    match received_clientrecoveryresponse_opt with
    | None -> (* no such replica exists *) assert(false)
    | Some(received_clientrecoveryresponse) -> 
      if received_clientrecoveryresponse then
        (* already received a clientrecoveryresponse from this replica *)
        (state, [])
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
           }, [])