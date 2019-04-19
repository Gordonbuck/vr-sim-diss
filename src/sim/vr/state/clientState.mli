module ClientState (StateMachine : StateMachine.StateMachine_type) : sig 

  type client_state = {
    configuration : int list;
    view_no : int;
    client_id : int;
    request_no : int;
    next_op_index : int;
    operations_to_do : StateMachine.operation list;
    recovering : bool;
    no_clientrecoveryresponses : int;
    received_clientrecoveryresponses : bool list;
    valid_timeout : int;
    clock : float;
  }

  type client_message =
    | Reply of int * int * StateMachine.result
    | ClientRecoveryResponse of int * int * int

  type client_timeout = 
    | RequestTimeout of int
    | ClientRecoveryTimeout of int

  val init_clients: int -> int -> client_state list
  val crash_client: client_state -> client_state
  val index_of_client: client_state -> int

end
