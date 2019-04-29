open Core
open EventList

module type Protocol_type = sig
  
  type replica_state
  type client_state
  type replica_message
  type client_message
  type replica_timeout
  type client_timeout
  type message = ReplicaMessage of replica_message | ClientMessage of client_message
  type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list
  type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int
  type protocol_event = Communication of communication | Timeout of timeout

  type trace
  type trace_level

  val on_replica_message: replica_message -> replica_state -> replica_state * protocol_event list * trace
  val on_replica_timeout: replica_timeout -> replica_state -> replica_state * protocol_event list * trace
  val init_replicas: int -> int -> replica_state list
  val crash_replica: replica_state -> replica_state
  val start_replica: replica_state -> replica_state * protocol_event list * trace
  val recover_replica: replica_state -> replica_state * protocol_event list * trace
  val index_of_replica: replica_state -> int
  val check_consistency: replica_state list -> bool
  val replica_is_recovering: replica_state -> bool
  val replica_set_time: replica_state -> float -> replica_state

  val on_client_message: client_message -> client_state -> client_state * protocol_event list * trace
  val on_client_timeout: client_timeout -> client_state -> client_state * protocol_event list * trace
  val init_clients: int -> int -> client_state list
  val crash_client: client_state -> client_state
  val start_client: client_state -> client_state * protocol_event list * trace
  val recover_client: client_state -> client_state * protocol_event list * trace
  val index_of_client: client_state -> int
  val gen_workload: client_state -> int -> client_state
  val finished_workloads: client_state list -> bool
  val client_is_recovering: client_state -> bool
  val client_set_time: client_state -> float -> client_state

  val string_of_trace: trace -> trace_level -> string

end

module type Parameters_type = sig 

  type replica_timeout
  type client_timeout
  type termination_type = Timelimit of float | WorkCompletion
  type trace_level

  val n_replicas: int
  val n_clients: int
  val max_replica_failures: int
  val max_client_failures: int
  val n_iterations: int
  val workloads: int list
  val drop_packet: unit -> bool
  val duplicate_packet: unit -> bool
  val packet_delay: unit -> float
  val time_for_replica_timeout: replica_timeout -> float
  val time_for_client_timeout: client_timeout -> float
  val clock_skew: unit -> float
  val replica_failure_period: float
  val fail_replica: unit -> (float * float) option
  val client_failure_period: float
  val fail_client: unit -> (float * float) option
  val termination: termination_type
  val trace_level: trace_level
  val show_trace: bool

end

module Simulator (P : Protocol_type) 
    (Params : Parameters_type 
     with type replica_timeout = P.replica_timeout 
     with type client_timeout = P.client_timeout
     with type trace_level = P.trace_level) = struct

  module T = SimTime
  module EL = EventHeap

  type 'protocol_state state = { alive : bool; protocol_state: 'protocol_state }
  type replica_state =  P.replica_state state
  type client_state = P.client_state state

  type event = 
    | ReplicaEvent of T.t * int * (replica_state -> replica_state * event list)
    | ClientEvent of T.t * int * (client_state -> client_state * event list)
    | SystemEvent of T.t * (replica_state list -> client_state list -> event list)

  let time_of_event e = 
    match e with
    | ReplicaEvent(t, _, _)
    | ClientEvent(t, _, _)
    | SystemEvent(t, _) -> t

  let compare_events e1 e2 = T.compare (time_of_event e1) (time_of_event e2)

  let print_trace t trace = 
    if Params.show_trace then
      let string_trace = P.string_of_trace trace Params.trace_level in
      if String.equal string_trace "" then ()
      else Printf.printf "time %f; %s\n" (T.float_of_t t) string_trace
    else ()

  let client_broadcast_indices state = 
    (List.init (Params.n_replicas) (fun i -> i), 
     List.filteri (List.init (Params.n_clients) (fun i -> i)) (fun i _ -> i <> (P.index_of_client state.protocol_state)))

  let replica_broadcast_indices state = 
    (List.filteri (List.init (Params.n_replicas) (fun i -> i)) (fun i _ -> i <> (P.index_of_replica state.protocol_state)),
     List.init (Params.n_clients) (fun i -> i))

  let client_message_times state = 
    (List.init (Params.n_replicas) (fun i -> Params.packet_delay ()), 
     List.init (Params.n_clients) (fun i -> if i = (P.index_of_client state.protocol_state) then 0. else Params.packet_delay ()))

  let replica_message_times state = 
    (List.init (Params.n_replicas) (fun i -> if i = (P.index_of_replica state.protocol_state) then 0. else Params.packet_delay ()), 
     List.init (Params.n_clients) (fun i -> Params.packet_delay ()))

      (* protocol events *)

  let rec build_replica_msg_events t i msg r_msg_times = 
    if Params.drop_packet () then
      []
    else
      let span_f = 
        match List.nth r_msg_times i with 
        | None -> assert(false)
        | Some(span) -> span in
      let t1 = T.inc t (T.span_of_float (span_f)) in
      let events = [ReplicaEvent(t1, i, replica_protocol_event t1 (P.on_replica_message msg))] in
      if Params.duplicate_packet () then
        let span_f = 
          match List.nth r_msg_times i with 
          | None -> assert(false)
          | Some(span) -> span in
        let t2 = T.inc t (T.span_of_float (span_f)) in
        ReplicaEvent(t2, i, replica_protocol_event t2 (P.on_replica_message msg))::events
      else
        events
  and build_client_msg_events t i msg c_msg_times = 
    if Params.drop_packet () then
      []
    else
      let span_f = 
        match List.nth c_msg_times i with 
        | None -> assert(false)
        | Some(span) -> span in
      let t1 = T.inc t (T.span_of_float (span_f)) in
      let events = [ClientEvent(t1, i, client_protocol_event t1 (P.on_client_message msg))] in
      if Params.duplicate_packet () then
        let span_f = 
          match List.nth c_msg_times i with 
          | None -> assert(false)
          | Some(span) -> span in
        let t2 = T.inc t (T.span_of_float (span_f)) in
        ClientEvent(t2, i, client_protocol_event t2 (P.on_client_message msg))::events
      else
        events
  and build_replica_timeout_event t i timeout =  
    let t = T.inc (T.inc t (T.span_of_float (Params.time_for_replica_timeout timeout))) (T.span_of_float (Params.clock_skew ())) in
    ReplicaEvent(t, i, replica_protocol_event t (P.on_replica_timeout timeout))
  and build_client_timeout_event t i timeout = 
    let t = T.inc (T.inc t (T.span_of_float (Params.time_for_client_timeout timeout))) (T.span_of_float (Params.clock_skew ())) in
    ClientEvent(t, i, client_protocol_event t (P.on_client_timeout timeout))

  and timeout_to_event t timeout = 
    match timeout with
    | P.ReplicaTimeout(timeout, i) -> build_replica_timeout_event t i timeout
    | P.ClientTimeout(timeout, i) -> build_client_timeout_event t i timeout

  and msg_to_events t i msg (r_msg_times, c_msg_times) = 
    match msg with
    | P.ReplicaMessage(msg) -> build_replica_msg_events t i msg r_msg_times 
    | P.ClientMessage(msg) -> build_client_msg_events t i msg c_msg_times

  and broadcast_msg_to_events t msg (r_inds, c_inds) (r_msg_times, c_msg_times) = 
    match msg with
    | P.ReplicaMessage(msg) -> 
      List.fold (List.map r_inds (fun i -> build_replica_msg_events t i msg r_msg_times)) ~init:[] ~f:(List.append)
    | P.ClientMessage(msg) -> 
      List.fold (List.map c_inds (fun i -> build_client_msg_events t i msg c_msg_times)) ~init:[] ~f:(List.append)

  and comm_to_events t comm inds msg_times = 
    match comm with
    | P.Unicast(msg, i) -> msg_to_events t i msg msg_times
    | P.Broadcast(msg) -> broadcast_msg_to_events t msg inds msg_times
    | P.Multicast(msg, indices) -> 
      List.fold (List.map indices (fun i -> msg_to_events t i msg msg_times)) ~init:[] ~f:(List.append)

  and protocol_events_to_events t pevents inds msg_times = 
    let rec inner l acc =
      match l with
      | [] -> acc
      | e::l ->
        let new_events = 
          match e with
          | P.Communication(comm) -> comm_to_events t comm inds msg_times
          | P.Timeout(timeout) -> [timeout_to_event t timeout] in
        inner l (new_events@acc) in
    inner pevents []

  and replica_protocol_event t comp state = 
    if not state.alive then
      (state, [])
    else
      let (protocol_state, pevents, trace) = comp state.protocol_state in
      let inds = replica_broadcast_indices state in
      let msg_times = replica_message_times state in
      let events = protocol_events_to_events t pevents inds msg_times in
      print_trace t trace;
      ({state with 
        protocol_state = protocol_state;
       }, events)

  and client_protocol_event t comp state = 
    if not state.alive then
      (state, [])
    else
      let (protocol_state, pevents, trace) = comp state.protocol_state in
      let inds = client_broadcast_indices state in
      let msg_times = client_message_times state in
      let events = protocol_events_to_events t pevents inds msg_times in
      print_trace t trace;
      ({state with 
        protocol_state = protocol_state;
       }, events)

        (* crash events *)

  let fail_replica t state = 
    let protocol_state = P.crash_replica state.protocol_state in
    (if Params.show_trace then
      (Printf.printf "time %f; crashing replica %i\n" (T.float_of_t t) (P.index_of_replica state.protocol_state))
    else ());
    ({alive = false; protocol_state = protocol_state;}, [])

  let fail_client t state = 
    let protocol_state = P.crash_client state.protocol_state in
    (if Params.show_trace then
       (Printf.printf "time %f; crashing client %i\n" (T.float_of_t t) (P.index_of_client state.protocol_state))
    else ());
    ({alive = false; protocol_state = protocol_state;}, [])

  let recover_replica t state = 
    let (protocol_state, pevents, trace) = P.recover_replica state.protocol_state in
    let inds = replica_broadcast_indices state in
    let msg_times = replica_message_times state in 
    let events = protocol_events_to_events t pevents inds msg_times in
    print_trace t trace;
    ({alive = true;
      protocol_state = protocol_state;
     }, events)

  let recover_client t state = 
    let (protocol_state, pevents, trace) = P.recover_client state.protocol_state in
    let inds = client_broadcast_indices state in
    let msg_times = client_message_times state in 
    let events = protocol_events_to_events t pevents inds msg_times in
    print_trace t trace;
    ({alive = true;
      protocol_state = protocol_state;
     }, events)

  let n_dead is_recovering states = 
    let rec n_dead states n =
      match states with
      | [] -> n
      | (s::states) -> n_dead states (if s.alive && not (is_recovering s.protocol_state) then n else n+1) in
    n_dead states 0

  let rec compute_replica_crashes t replicas _ = 
    let rec fail replicas rev_replicas events i n_failed = 
      match replicas with
      | [] -> events
      | r::replicas ->
        if n_failed + (n_dead P.replica_is_recovering ((r::replicas)@rev_replicas)) >= Params.max_replica_failures then events
        else
          let (n_failed, events) = 
            if r.alive then
              match (Params.fail_replica ()) with
              | None -> (n_failed, events)
              | Some(t_fail, t_recover) -> 
                let t_fail = T.inc t (T.span_of_float t_fail) in
                let t_recover = T.inc t_fail (T.span_of_float t_recover) in
                (n_failed+1, (ReplicaEvent(t_fail, i, fail_replica t_fail))::(ReplicaEvent(t_recover, i, recover_replica t_recover))::events)
            else 
              (n_failed, events) in
          fail replicas (r::rev_replicas) events (i+1) n_failed in
    let t_next = T.inc t (T.span_of_float Params.replica_failure_period) in
    SystemEvent(t_next, compute_replica_crashes t_next)::(fail replicas ([]) ([]) 0 0)

    let rec compute_client_crashes t _ clients = 
      let rec fail clients rev_clients events i n_failed = 
        match clients with
        | [] -> events
        | c::clients ->
          if n_failed + (n_dead P.client_is_recovering ((c::clients)@rev_clients)) >= Params.max_client_failures then events
          else
            let (n_failed, events) = 
              if c.alive then
                match (Params.fail_client ()) with
                | None -> (n_failed, events)
                | Some(t_fail, t_recover) -> 
                  let t_fail = T.inc t (T.span_of_float t_fail) in
                  let t_recover = T.inc t_fail (T.span_of_float t_recover) in
                  (n_failed+1, (ClientEvent(t_fail, i, fail_client t_fail))::(ClientEvent(t_recover, i, recover_client t_recover))::events)
              else 
                (n_failed, events) in
            fail clients (c::rev_clients) events (i+1) n_failed in
      let t_next = T.inc t (T.span_of_float Params.client_failure_period) in
      SystemEvent(t_next, compute_client_crashes t_next)::(fail clients ([]) ([]) 0 0)

      (* initalization *)

  let gen_replicas n_replicas n_clients = 
    let protocol_states = P.init_replicas n_replicas n_clients in
    List.map protocol_states (fun s -> {alive = true; protocol_state = s})

  let gen_clients n_replicas n_clients workload_sizes = 
    let protocol_states = P.init_clients n_replicas n_clients in
    let protocol_states_opt = List.map2 protocol_states workload_sizes (fun s w -> P.gen_workload s w) in
    match protocol_states_opt with
    | Unequal_lengths -> assert(false)
    | Ok(protocol_states) -> List.map protocol_states (fun s -> {alive = true; protocol_state = s})

  let initial_replica_events t states = 
    let (states, events_l) = List.unzip (List.map states (fun state -> 
        let (protocol_state, pevents, trace) = P.start_replica state.protocol_state in
        let inds = replica_broadcast_indices state in
        let msg_times = replica_message_times state in
        let events = protocol_events_to_events t pevents inds msg_times in
        print_trace t trace;
        ({state with protocol_state = protocol_state;}, events)
      )) in
    let events = List.fold events_l ~init:[] ~f:List.append in
    (states, events)

  let initial_client_events t states = 
    let (states, events_l) = List.unzip (List.map states (fun state -> 
        let (protocol_state, pevents, trace) = P.start_client state.protocol_state in
        let inds = client_broadcast_indices state in
        let msg_times = client_message_times state in
        let events = protocol_events_to_events t pevents inds msg_times in
        print_trace t trace;
        ({state with protocol_state = protocol_state;}, events)
      )) in
    let events = List.fold events_l ~init:[] ~f:List.append in
    (states, events)

  let initial_system_events t _ _ = [SystemEvent(t, compute_replica_crashes t);SystemEvent(t, compute_client_crashes t)]

      (* termination *)

  let should_terminate replicas clients e = 
    match Params.termination with
    | Timelimit(t_float) -> 
      T.compare (time_of_event e) (T.t_of_float t_float) >= 0
    | WorkCompletion -> 
      let protocol_clients = List.map clients (fun c -> c.protocol_state) in
      P.finished_workloads protocol_clients

      (* simulation *)

  let simulate t states eventlist i comp time_update = 
    let states = List.map states (fun s -> {s with protocol_state = (time_update s.protocol_state (T.float_of_t (T.inc t (T.span_of_float (Params.clock_skew ())))));}) in
    let state_opt = List.nth states i in
    match state_opt with
    | None -> assert(false)
    | Some(state) ->
      let (state, events) = comp state in
      let states = List.mapi states (fun j s -> if j = i then state else s) in
      let eventlist = EL.add_multi eventlist events in
      (states, eventlist)

  let rec sim_loop t replicas clients eventlist = 
    let event_opt = EL.pop eventlist in
    match event_opt with
    | None -> Printf.printf "No more events to simulate, terminating\n"
    | Some(e, eventlist) ->
      if should_terminate replicas clients e then
        Printf.printf "Work completed, terminating\n"
      else
        let (t, replicas, clients, eventlist) = 
          match e with
          | ReplicaEvent(t, i, comp) -> 
            let (replicas, eventlist) = simulate t replicas eventlist i comp P.replica_set_time in
            (t, replicas, clients, eventlist)
          | ClientEvent(t, i, comp) -> 
            let (clients, eventlist) = simulate t clients eventlist i comp P.client_set_time in
            (t, replicas, clients, eventlist) 
          | SystemEvent(t, comp) ->
            let eventlist = EL.add_multi eventlist (comp replicas clients) in
            (t, replicas, clients, eventlist) in
        let protocol_replicas = List.map replicas (fun r -> r.protocol_state) in
        if P.check_consistency protocol_replicas then
          sim_loop t replicas clients eventlist
        else
          (Printf.printf "Consistency check failed, terminating\n"; exit 0)

  let run () = 
    let rec inner i = 
      if i > Params.n_iterations then ()
      else
        let replicas = gen_replicas Params.n_replicas Params.n_clients in
        let clients = gen_clients Params.n_replicas Params.n_clients Params.workloads in
        let (replicas, replica_events) = initial_replica_events (T.t_of_float 0.) replicas in
        let (clients, client_events) = initial_client_events (T.t_of_float 0.) clients in
        let system_events = initial_system_events (T.t_of_float 0.) replicas clients in
        let eventlist = EL.add_multi (EL.add_multi (EL.add_multi (EL.create compare_events) replica_events) client_events) system_events in
        sim_loop (T.t_of_float 0.) replicas clients eventlist;
        Printf.printf "%!";
        inner (i + 1) in
    inner (1)

end
