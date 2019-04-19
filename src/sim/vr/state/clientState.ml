module ClientState (StateMachine : StateMachine.StateMachine_type) = struct 

  type client_state = {
    (* protocol state *)
    configuration : int list;
    view_no : int;
    client_id : int;
    request_no : int;

    (* index of next operation to be sent in request*)
    next_op_index : int;
    (* list of operations client wants to perform *)
    operations_to_do : StateMachine.operation list;

    (* indicates if the client is recovering from a crash or not *)
    recovering : bool;
    (* the number of clientrecoveryresponses received for current recovery *)
    no_clientrecoveryresponses : int;
    (* for each replica indicates whether they have responded to recovery or not *)
    received_clientrecoveryresponses : bool list;

    (* increment on replies and recovery *)
    valid_timeout : int;

    (* time *)
    clock : float;
  }

  type client_message =
    | Reply of int * int * StateMachine.result
    | ClientRecoveryResponse of int * int * int

  type client_timeout = 
    | RequestTimeout of int
    | ClientRecoveryTimeout of int

  let init_clients n_replicas n_clients = 
    let rec init n_c l = 
      if n_c < 0 then
        l
      else
        let state = {
          configuration = List.init n_replicas (fun i -> i);
          view_no = 0;
          client_id = n_c;
          request_no = -1;

          next_op_index = 0;
          operations_to_do = [];

          recovering = false;
          no_clientrecoveryresponses = 0;
          received_clientrecoveryresponses = List.init n_replicas (fun _ -> false);

          valid_timeout = 0;

          clock = 0.
        } in
        init (n_c - 1) (state::l) in
    init (n_clients - 1) []

  let crash_client (state : client_state) =
    let n_replicas = List.length state.configuration in
    {
      configuration = state.configuration;
      view_no = 0;
      client_id = state.client_id;
      request_no = -1;

      next_op_index = state.next_op_index;
      operations_to_do = state.operations_to_do;

      recovering = false;
      no_clientrecoveryresponses = 0;
      received_clientrecoveryresponses = List.init n_replicas (fun _ -> false);

      valid_timeout = state.valid_timeout;

      clock = 0.
    }

  let finished_workloads clients = 
    let rec inner clients = 
      match clients with
      | [] -> true
      | (c::clients) -> 
        if (c.next_op_index < (List.length c.operations_to_do) + 1) then false
        else inner clients in
    inner clients

  let index_of_client state = state.client_id

end
