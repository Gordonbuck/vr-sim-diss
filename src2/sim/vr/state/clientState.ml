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
  }

  type client_message =
    | Reply of int * int * StateMachine.result
    | ClientRecoveryResponse of int * int * int

  type client_timeout = 
    | RequestTimeout of int
    | ClientRecoveryTimeout of int

end
