open Core

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

  val on_replica_message: replica_message -> replica_state -> replica_state * protocol_event list
  val on_replica_timeout: replica_timeout -> replica_state -> replica_state * protocol_event list
  val init_replicas: int -> int -> replica_state list
  val crash_replica: replica_state -> replica_state
  val start_replica: replica_state -> replica_state * protocol_event list
  val recover_replica: replica_state -> replica_state * protocol_event list
  val index_of_replica: replica_state -> int


  val on_client_message: client_message -> client_state -> client_state * protocol_event list
  val on_client_timeout: client_timeout -> client_state -> client_state * protocol_event list
  val init_clients: int -> int -> client_state list
  val crash_client: client_state -> client_state
  val start_client: client_state -> client_state * protocol_event list
  val recover_client: client_state -> client_state * protocol_event list
  val index_of_client: client_state -> int
  val gen_workload: client_state -> int -> client_state
end

module VR = struct

  module StateMachine = StateMachine.KeyValueStore

  (* type declarations *)

  type status =
    | Normal
    | ViewChange
    | Recovering

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

  type replica_state = {
    (* protocol state *)
    configuration : int list;
    replica_no : int;
    view_no : int;
    status: status;
    op_no : int;
    log: (StateMachine.operation * int * int) list;
    commit_no : int;
    client_table: (int * StateMachine.result option) list;

    (* list of operations depending on previous operations not yet seen *)
    queued_prepares : (StateMachine.operation * int * int) option list;
    (* for each not yet committed operation, the number of prepareoks received *)
    waiting_prepareoks : int list;
    (* for each replica, the highest op_no seen in a prepareok message *)
    casted_prepareoks : int list;
    (* the higest commit_no seen in a prepare/commit message *)
    highest_seen_commit_no : int;

    (* number of startviewchange messages received from different replicas *)
    no_startviewchanges : int;
    (* for each replica, indicates whether this has received a startviewchange from them *)
    received_startviewchanges : bool list;
    (* list of doviewchange messages received *)
    doviewchanges : (int * (StateMachine.operation * int * int) list * int * int * int * int) list;
    (* view_no of the last view for which status was normal *)
    last_normal_view_no : int;

    (* the nonce used in this replica's most recent recovery *)
    recovery_nonce : int; 
    (* number of recoveryresponse messages received from different replicas *)
    no_recoveryresponses : int;
    (* for each replica, indicates whether this has received a recoveryresponse from them *)
    received_recoveryresponses : bool list;
    (* recoveryresponse message from primary of latest view seen in recoveryresponse messages *)
    primary_recoveryresponse : (int * int * (StateMachine.operation * int * int) list * int * int * int) option;

    (* increment on recovery and view change *)
    valid_timeout : int;
    (* if primary: no. communications sent, else: no. communications received from primary*)
    no_primary_comms : int;

    (* replicated state machine *)
    mach : StateMachine.t;
  }

  type client_message =
    | Reply of int * int * StateMachine.result
    | ClientRecoveryResponse of int * int * int

  type replica_message =
    | Request of StateMachine.operation * int * int
    | Prepare of int * (StateMachine.operation * int * int) * int * int
    | PrepareOk of int * int * int
    | Commit of int * int
    | StartViewChange of int * int
    | DoViewChange of int * (StateMachine.operation * int * int) list * int * int * int * int
    | StartView of int * (StateMachine.operation * int * int) list * int * int
    | Recovery of int * int
    | RecoveryResponse of int * int * ((StateMachine.operation * int * int) list * int * int) option * int
    | ClientRecovery of int
    | GetState of int * int * int
    | NewState of int * (StateMachine.operation * int * int) list * int * int

  type client_timeout = 
    | RequestTimeout of int
    | ClientRecoveryTimeout of int

  type replica_timeout = 
    | HeartbeatTimeout of int * int
    | PrepareTimeout of int * int
    | PrimaryTimeout of int * int
    | StateTransferTimeout of int * int
    | StartViewChangeTimeout of int
    | DoViewChangeTimeout of int
    | RecoveryTimeout of int
    | GetStateTimeout of int * int

  type message = ReplicaMessage of replica_message | ClientMessage of client_message

  type communication = Unicast of message * int |  Broadcast of message | Multicast of message * int list

  type timeout = ReplicaTimeout of replica_timeout * int | ClientTimeout of client_timeout * int

  type protocol_event = Communication of communication | Timeout of timeout

  (* utils *)

  let is_primary state = 
    state.view_no mod (List.length state.configuration) = state.replica_no

  let primary_no v conf = 
    v mod (List.length conf)

  let update_ct ?(res=None) ct c s = List.mapi ct (fun i cte -> if i = c then (s, res) else cte)

  let rec update_ct_reqs ct reqs = 
    match reqs with
    | (op, c, s)::reqs -> update_ct_reqs (update_ct ct c s) reqs
    | [] -> ct

  let rec add_nones l n = 
    match n with 
    | _ when n < 1 -> l
    | n -> add_nones (None::l) (n - 1)

  let process_queued_prepares queued_prepares =
    let rec process_queued_prepares rev_queued_prepares prepared =
      match rev_queued_prepares with
      | (None::_) | [] -> (rev_queued_prepares, prepared)
      | (Some(req)::rev_queued_prepares) -> process_queued_prepares rev_queued_prepares (req::prepared) in
    let (rev_queued_prepares, prepared) = process_queued_prepares (List.rev queued_prepares) [] in
    (List.rev rev_queued_prepares, prepared)

  let process_waiting_prepareoks f waiting_prepareoks = 
    let rec process_waiting_prepareoks rev_waiting_prepareoks n = 
      match rev_waiting_prepareoks with
      | [] -> (rev_waiting_prepareoks, n)
      | w::rev_waiting_prepareoks -> 
        if w < f then 
          (w::rev_waiting_prepareoks, n)
        else 
          process_waiting_prepareoks rev_waiting_prepareoks (n+1) in
    let (rev_waiting_prepareoks, rev_index) = process_waiting_prepareoks (List.rev waiting_prepareoks) (-1) in
    (List.rev rev_waiting_prepareoks, (List.length waiting_prepareoks) - 1 - rev_index)

  let commit_all view_no mach ct reqs = 
    let rec commit_all mach ct reqs replies = 
      match reqs with 
      | (op, c, s)::reqs -> 
        let mach = StateMachine.apply_op mach op in
        let res = StateMachine.last_res mach in
        let ct = update_ct ct c s ~res:(Some(res)) in
        commit_all mach ct reqs (Unicast(ClientMessage(Reply(view_no, s, res)), c)::replies)
      | _ -> (mach, ct, replies) in
    commit_all mach ct reqs []

  let process_doviewchanges doviewchanges =
    let rec process_doviewchanges doviewchanges log last_normal_view_no op_no commit_no = 
      match doviewchanges with 
      | [] -> (log, last_normal_view_no, op_no, commit_no)
      | (v, l, v', n, k, i)::doviewchanges -> 
        let (log, last_normal_view_no, op_no) = 
          if (v' > last_normal_view_no || (v' = last_normal_view_no && n > op_no)) then 
            (l, v', n)
          else
            (log, last_normal_view_no, op_no) in
        let commit_no = if (k > commit_no) then k else commit_no in
        process_doviewchanges doviewchanges log last_normal_view_no op_no commit_no in
    process_doviewchanges doviewchanges [] 0 0 0

  let rec received_doviewchange doviewchanges i = 
    match doviewchanges with
    | [] -> false
    | (_, _, _, _, _, j)::doviewchanges -> if i = j then true else received_doviewchange doviewchanges i

  let map_falses l f =
    let rec map_falses l f i acc = 
      match l with
      | [] -> acc
      | (b::bs) -> if b then map_falses bs f (i+1) acc else map_falses bs f (i+1) ((f i)::acc) in
    map_falses l f 0 []

  (* normal operation protocol implementation *)

  let on_request state op c s =
    if (is_primary state) then
      let cte_opt = List.nth state.client_table c in
      match cte_opt with 
      | None -> (* no client table entry for this client id *) assert(false)
      | Some(cte_s, res_opt) -> 
        if (s = cte_s) then
          (* request already being/been executed, try to return result *)
          match res_opt with
          | None -> (* no result to return *) (state, [])
          | Some(res) -> (* return result for most recent operation *) 
            (state, [Communication(Unicast(ClientMessage(Reply(state.view_no, s, res)), c))])
        else if (s > cte_s) then
          (* begin protocol to execute new request *)
          let op_no = state.op_no + 1 in
          let log = (op, c, s)::state.log in
          let client_table = update_ct state.client_table c s in
          let waiting_prepareoks = 0::state.waiting_prepareoks in
          let communication = Broadcast(ReplicaMessage(Prepare(state.view_no, (op, c, s), op_no, state.commit_no))) in
          let prepare_timeout = ReplicaTimeout(PrepareTimeout(state.valid_timeout, op_no), state.replica_no) in
          let heartbeat_timeout = ReplicaTimeout(HeartbeatTimeout(state.valid_timeout, op_no), state.replica_no) in
          ({state with 
            op_no = op_no;
            log = log;
            client_table = client_table;
            waiting_prepareoks = waiting_prepareoks;
           }, [Communication(communication); Timeout(heartbeat_timeout); Timeout(prepare_timeout)])
        else
          (* drop request *) (state, [])
    else
      (state, [])

  let on_prepare state v (op, c, s) n k = 
    let state = {state with no_primary_comms = state.no_primary_comms+1;} in
    let primary_no = primary_no state.view_no state.configuration in
    let primary_timeout = ReplicaTimeout(PrimaryTimeout(state.valid_timeout, state.no_primary_comms), state.replica_no) in
    if state.op_no >= n then
      (* already prepared request so re-send prepareok *)
      let communication = Unicast(ReplicaMessage(PrepareOk(state.view_no, state.op_no, state.replica_no)), primary_no) in
      (state, [Communication(communication); Timeout(primary_timeout)])
    else
      (* try to prepare request, may not be able to without earlier requests, and send prepareok if prepared anything *)
      let no_queued = List.length state.queued_prepares in
      let index = state.op_no + no_queued - n in
      let queued_prepares = 
        if (index >= 0) then 
          List.mapi state.queued_prepares (fun i req_opt -> if i = index then Some((op, c, s)) else req_opt)
        else 
          Some((op, c, s))::(add_nones state.queued_prepares (-(index + 1))) in    
      let (queued_prepares, prepared) = process_queued_prepares queued_prepares in
      let op_no = state.op_no + List.length prepared in
      let log = List.append prepared state.log in
      let client_table = update_ct_reqs state.client_table (List.rev prepared) in
      let events = 
        if op_no > state.op_no then 
          [Communication(Unicast(ReplicaMessage(PrepareOk(state.view_no, op_no, state.replica_no)), primary_no))]
        else 
          [Timeout(ReplicaTimeout(StateTransferTimeout(state.valid_timeout, state.op_no), state.replica_no))] in
      ({state with 
        op_no = op_no;
        log = log;
        client_table = client_table;
        queued_prepares = queued_prepares;
       }, Timeout(primary_timeout)::events)

  let on_prepareok state v n i = 
    let casted_prepareok_opt = List.nth state.casted_prepareoks i in
    match casted_prepareok_opt with
    | None -> (* no such replica *) assert(false)
    | Some(casted_prepareok) ->
      if casted_prepareok >= n || state.commit_no >= n then
        (* either already received a prepareok from this replica or already committed operation *)
        (state, [])
      else
        let f = ((List.length state.configuration) / 2) in
        let no_waiting = List.length state.waiting_prepareoks in
        let index = state.commit_no + no_waiting - n in
        let last_casted_index = state.commit_no + no_waiting - casted_prepareok in
        let waiting_prepareoks = List.mapi state.waiting_prepareoks (fun i w -> if i >= index && i < last_casted_index then w+1 else w) in
        let (waiting_prepareoks, commit_until) = process_waiting_prepareoks f waiting_prepareoks in 
        let last_committed_index = (List.length state.log) - 1 - state.commit_no in
        let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
        let (mach, client_table, replies) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
        let commit_no = state.commit_no + (List.length to_commit) in
        let comms = List.map replies (fun c -> Communication(c)) in
        let casted_prepareoks = List.mapi state.casted_prepareoks (fun idx m -> if idx = i then n else m) in
        ({state with 
          commit_no = commit_no;
          client_table = client_table;
          waiting_prepareoks = waiting_prepareoks;
          casted_prepareoks = casted_prepareoks;
          mach = mach;
         }, comms)

  let on_commit state v k = 
    let state = {state with no_primary_comms = state.no_primary_comms+1;} in
    let k = max state.highest_seen_commit_no k in
    let commit_until = (List.length state.log) - 1 - k in
    let last_committed_index = (List.length state.log) - 1 - state.commit_no in
    let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
    let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
    let commit_no = state.commit_no + (List.length to_commit) in
    ({state with 
      commit_no = commit_no;
      client_table = client_table;
      highest_seen_commit_no = k;
      mach = mach;
     }, [Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, state.no_primary_comms), state.replica_no))])

  (* view change protocol implementation *)

  let notice_viewchange state = 
    let view_no = state.view_no + 1 in 
    let status = ViewChange in
    let no_startviewchanges = 0 in
    let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
    let valid_timeout = state.valid_timeout + 1 in
    ({state with 
      view_no = view_no;
      status = status;
      no_startviewchanges = no_startviewchanges;
      received_startviewchanges = received_startviewchanges;
      valid_timeout = valid_timeout;
     }, [Communication(Broadcast(ReplicaMessage(StartViewChange(view_no, state.replica_no))));
         Timeout(ReplicaTimeout(StartViewChangeTimeout(valid_timeout), state.replica_no))])

  let on_startviewchange state v i =
    let received_startviewchange_opt = List.nth state.received_startviewchanges i in
    match received_startviewchange_opt with
    | None -> (* no replica for this index *) assert(false)
    | Some(received_startviewchange) ->
      if received_startviewchange then
        (* already received a startviewchange from this replica*)
        (state, [])
      else
        let f = ((List.length state.configuration) / 2) in
        let no_startviewchanges = state.no_startviewchanges + 1 in
        let primary_no = primary_no state.view_no state.configuration in
        let received_startviewchanges = List.mapi state.received_startviewchanges (fun idx b -> if idx = i then true else b) in
        let events = 
          if (no_startviewchanges = f) then
            let msg = DoViewChange(state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no) in
            let comm = Unicast(ReplicaMessage(msg), primary_no) in
            [Communication(comm); 
             Timeout(ReplicaTimeout(DoViewChangeTimeout(state.valid_timeout), state.replica_no));
             Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, state.no_primary_comms), state.replica_no))]
          else [] in
        ({state with 
          no_startviewchanges = no_startviewchanges;
          received_startviewchanges = received_startviewchanges;
         }, events)

  let on_doviewchange state v l v' n k i =
    if state.status = Normal then
      (* recovered, re-send startview message *)
      (state, [Communication(Unicast(ReplicaMessage(StartView(state.view_no, state.log, state.op_no, state.commit_no)), i))])
    else
      let received_doviewchange = received_doviewchange state.doviewchanges i in
      if received_doviewchange then
        (* already received a doviewchange message from this replica *)
        (state, [])
      else  
        let f = ((List.length state.configuration) / 2) in
        let no_doviewchanges = (List.length state.doviewchanges) + 1 in
        let doviewchanges = (v, l, v', n, k, i)::state.doviewchanges in
        if (no_doviewchanges = f + 1) then
          let status = Normal in 
          let view_no = v in
          let (log, last_normal_view_no, op_no, commit_no) = process_doviewchanges doviewchanges in
          let last_committed_index = (List.length state.log) - 1 - state.commit_no in
          let commit_until = (List.length state.log) - 1 - commit_no in
          let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
          let (mach, client_table, replies) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
          let waiting_prepareoks = List.init (op_no - commit_no) (fun _ -> 0) in
          let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
          let casted_prepareoks = List.map state.casted_prepareoks (fun _ -> commit_no) in
          let valid_timeout = state.valid_timeout + 1 in
          let events = List.map replies (fun c -> Communication(c)) in
          let timeout = ReplicaTimeout(HeartbeatTimeout(state.replica_no, op_no), state.replica_no) in
          let comm = Broadcast(ReplicaMessage(StartView(view_no, log, op_no, commit_no))) in
          ({state with 
            view_no = view_no;
            status = status;
            op_no = op_no;
            log = log;
            commit_no = commit_no;
            client_table = client_table;
            queued_prepares = [];
            waiting_prepareoks = waiting_prepareoks;
            casted_prepareoks = casted_prepareoks;
            highest_seen_commit_no = commit_no;
            no_startviewchanges = 0;
            received_startviewchanges = received_startviewchanges;
            doviewchanges = [];
            last_normal_view_no = view_no;
            mach = mach;
            valid_timeout = valid_timeout;
            no_primary_comms = 0;
           }, Timeout(timeout)::Communication(comm)::events)
        else 
          ({state with 
            doviewchanges = doviewchanges;
           }, [])

  let on_startview state v l n k = 
    let view_no = v in
    let log = l in
    let op_no = n in
    let status = Normal in 
    let commit_no = k in
    let last_committed_index = (List.length state.log) - 1 - state.commit_no in
    let commit_until = (List.length state.log) - 1 - commit_no in
    let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
    let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
    let received_startviewchanges = List.map state.received_startviewchanges (fun _ -> false) in
    let primary_no = primary_no view_no state.configuration in
    let events = 
      if (commit_no < op_no) then
        [Communication(Unicast(ReplicaMessage(PrepareOk(view_no, op_no, state.replica_no)), primary_no))]
      else
        [] in
    let valid_timeout = state.valid_timeout + 1 in
    ({state with 
      view_no = view_no;
      status = status;
      op_no = op_no;
      log = log;
      commit_no = commit_no;
      client_table = client_table;
      queued_prepares = [];
      waiting_prepareoks = [];
      highest_seen_commit_no = commit_no;
      no_startviewchanges = 0;
      received_startviewchanges = received_startviewchanges;
      doviewchanges = [];
      last_normal_view_no = view_no;
      mach = mach;
      valid_timeout = valid_timeout;
      no_primary_comms = 0;
     }, Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout, 0), state.replica_no))::events)

  (* recovery protocol implementation *)

  let begin_recovery state = 
    let status = Recovering in
    let i = state.replica_no in
    let x = state.recovery_nonce + 1 in
    let valid_timeout = state.valid_timeout + 1 in
    ({state with 
      status = status;
      recovery_nonce = x;
      valid_timeout = valid_timeout;
     }, [Communication(Broadcast(ReplicaMessage(Recovery(i, x)))); 
         Timeout(ReplicaTimeout(RecoveryTimeout(valid_timeout), state.replica_no))])

  let on_recovery state i x =
    let v = state.view_no in
    let j = state.replica_no in
    if is_primary state then
      let l = state.log in
      let n = state.op_no in
      let k = state.commit_no in
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, Some(l, n, k), j)), i))])
    else
      (state, [Communication(Unicast(ReplicaMessage(RecoveryResponse(v, x, None, j)), i))])

  let on_recoveryresponse state v x opt_p j = 
    if state.recovery_nonce <> x then
      (state, [])
    else
      let received_recoveryresponse_opt = List.nth state.received_recoveryresponses j in
      match received_recoveryresponse_opt with
      | None -> (* no such replica *) assert(false)
      | Some(received_recoveryresponse) ->
        if received_recoveryresponse then
          (* already received a recovery response from this replica *)
          (state, [])
        else
          let no_recoveryresponses = state.no_recoveryresponses + 1 in
          let received_recoveryresponses = List.mapi state.received_recoveryresponses (fun i b -> if i = j then true else b) in
          let primary_recoveryresponse = 
            match opt_p with
            | Some(l, n, k) -> if v < state.view_no then state.primary_recoveryresponse else Some(v, x, l, n, k, j)
            | None -> if v > state.view_no then None else state.primary_recoveryresponse in
          let view_no = max v state.view_no in
          let f = ((List.length state.configuration) / 2) in
          if no_recoveryresponses >= f+1 then
            match state.primary_recoveryresponse with
            | Some(v, x, l, n, k, j) ->
              let log = l in
              let op_no = n in
              let status = Normal in 
              let commit_no = k in
              let last_committed_index = (List.length state.log) - 1 - state.commit_no in
              let commit_until = (List.length state.log) - 1 - commit_no in
              let to_commit = List.filteri state.log (fun i _ -> i < last_committed_index && i >= commit_until) in
              let (mach, client_table, _) = commit_all view_no state.mach state.client_table (List.rev to_commit) in
              let received_recoveryresponses = List.map state.received_recoveryresponses (fun _ -> false) in
              let valid_timeout = state.valid_timeout + 1 in
              ({state with 
                view_no = view_no;
                log = log;
                op_no = op_no;
                status = status;
                commit_no = k;
                client_table = client_table;
                no_recoveryresponses = 0;
                received_recoveryresponses = received_recoveryresponses;
                primary_recoveryresponse = None;
                mach = mach;
                valid_timeout = valid_timeout;
                no_primary_comms = 0;
               }, [Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout, 0), state.replica_no))])
            | None -> ({state with 
                        view_no = view_no;
                        no_recoveryresponses = no_recoveryresponses;
                        received_recoveryresponses = received_recoveryresponses;
                        primary_recoveryresponse = primary_recoveryresponse;
                       }, [])
          else
            ({state with 
              view_no = view_no;
              no_recoveryresponses = no_recoveryresponses;
              received_recoveryresponses = received_recoveryresponses;
              primary_recoveryresponse = primary_recoveryresponse;
             }, [])

  (* state transfer protocol implementation *)

  let begin_statetransfer state = 
    let primary_no = primary_no state.view_no state.configuration in
    (state, [Communication(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no));
             Timeout(ReplicaTimeout(GetStateTimeout(state.valid_timeout, state.op_no), state.replica_no))])

  let later_view state v = 
    let op_no = state.commit_no in
    let remove_until = state.op_no - state.commit_no in
    let log = List.drop state.log remove_until in
    let valid_timeout = state.valid_timeout + 1 in
    begin_statetransfer {state with 
                         view_no = v;
                         op_no = op_no;
                         log = log;
                         valid_timeout = valid_timeout;
                        }

  let on_getstate state v n' i = 
    let take_until = state.op_no - n' in
    let log = List.take state.log take_until in
    (state, [Communication(Unicast(ReplicaMessage(NewState(state.view_no, log, state.op_no, state.commit_no)), i))])

  let on_newstate state v l n k =
    if n <= state.op_no then
      (* replica has already got this state *)
      (state, [])
    else
      let log = List.append l state.log in
      let commit_until = (List.length log) - 1 - k in
      let last_committed_index = (List.length log) - 1 - state.commit_no in
      let to_commit = List.filteri log (fun i _ -> i < last_committed_index && i >= commit_until) in
      let (mach, client_table, _) = commit_all state.view_no state.mach state.client_table (List.rev to_commit) in
      let no_primary_comms = state.no_primary_comms + 1 in
      ({state with 
        op_no = n;
        log = log;
        commit_no = k;
        client_table = client_table;
        queued_prepares = [];
        waiting_prepareoks = [];
        mach = mach;
        no_primary_comms = no_primary_comms;
       }, [Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, no_primary_comms), state.replica_no))])

  (* client-side normal protocol implementation *)

  let start_sending (state : client_state) = 
    let op_opt = List.nth state.operations_to_do state.next_op_index in
    match op_opt with
    | None -> (* no operations left *) (state, [])
    | Some(op) -> (* send next request *) 
      let next_op_index = state.next_op_index + 1 in
      let primary_no = primary_no state.view_no state.configuration in
      let request_no = state.request_no + 1 in
      ({state with 
        request_no = request_no;
        next_op_index = next_op_index;
       }, [Communication(Unicast(ReplicaMessage(Request(op, state.client_id, request_no)), primary_no)); 
           Timeout(ClientTimeout(RequestTimeout(state.valid_timeout), state.client_id))])

  let on_reply state v s res = 
    if s < state.request_no || state.recovering then
      (* already received this reply or recovering so cant proceed *)
      (state, [])
    else
      let valid_timeout = state.valid_timeout + 1 in
      let state = {state with valid_timeout = valid_timeout;} in
      start_sending state

  (* client recovery protocol implementation *)

  let begin_clientrecovery (state : client_state) = 
    let valid_timeout = state.valid_timeout + 1 in
    ({state with 
      recovering = true;
      valid_timeout = valid_timeout;
     }, [Communication(Broadcast(ReplicaMessage(ClientRecovery(state.client_id)))); 
         Timeout(ClientTimeout(ClientRecoveryTimeout(valid_timeout), state.client_id))])

  let on_clientrecovery state c = 
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

  (* replica timeouts *)

  let on_heartbeat_timeout state n = 
    if state.op_no = n then
      (* send commit message as heartbeat *)
      (state, [Communication(Broadcast(ReplicaMessage(Commit(state.view_no, state.commit_no)))); 
               Timeout(ReplicaTimeout(HeartbeatTimeout(state.valid_timeout, state.op_no), state.replica_no))])
    else
      (state, [])

  let on_prepare_timeout state k = 
    if state.commit_no < k then
      (* havent committed the operation yet *)
      let req_opt = List.nth state.log k in
      match req_opt with
      | None -> (* no such request in log, should have been caught by valid timer tag *) assert(false)
      | Some(req) ->
        (* send prepare message to non-responsive replicas *)
        let received_prepareoks = List.map state.casted_prepareoks (fun m -> m >= k) in
        let indices = map_falses received_prepareoks (fun i -> i) in
        let multicast = Multicast(ReplicaMessage(Prepare(state.view_no, req, k, state.commit_no)), indices) in
        let prepare_timeout = ReplicaTimeout(PrepareTimeout(state.valid_timeout, k), state.replica_no) in
        (state, [Communication(multicast); Timeout(prepare_timeout)])
    else
      (state, [])

  let on_primary_timeout state n = 
    if state.no_primary_comms = n then
      (* no communication from primary since last timeout check, start viewchange *)
      notice_viewchange state
    else
      (state, [])

  let on_statetransfer_timeout state n = 
    if state.op_no <= n then
      (* haven't received missing prepare message, initiate state transfer *)
      begin_statetransfer state
    else
      (state, [])

  let on_startviewchange_timeout state = 
    (* re-send startviewchange messages to non-responsive replicas *)
    let indices = map_falses state.received_startviewchanges (fun i -> i) in
    let multicast = Multicast(ReplicaMessage(StartViewChange(state.view_no, state.replica_no)), indices) in
    (state, [Communication(multicast); Timeout(ReplicaTimeout(StartViewChangeTimeout(state.valid_timeout), state.replica_no))])

  let on_doviewchange_timeout state = 
    (* re-send doviewchange message to primary *)
    let primary_no = primary_no state.view_no state.configuration in
    let msg = DoViewChange(state.view_no, state.log, state.last_normal_view_no, state.op_no, state.commit_no, state.replica_no) in
    (state, [Communication(Unicast(ReplicaMessage(msg), primary_no)); 
             Timeout(ReplicaTimeout(DoViewChangeTimeout(state.valid_timeout), state.replica_no))])

  let on_recovery_timeout state = 
    (* re-send recovery messages to non-responsive replicas *)
    let indices = map_falses state.received_recoveryresponses (fun i -> i) in
    let multicast = Multicast(ReplicaMessage(Recovery(state.replica_no, state.recovery_nonce)), indices) in
    (state, [Communication(multicast); Timeout(ReplicaTimeout(RecoveryTimeout(state.valid_timeout), state.replica_no))])

  let on_getstate_timeout state n =
    if state.op_no <= n then
      (* havent updated log since request for more state, re-send request *)
      let primary_no = primary_no state.view_no state.configuration in
      (state, [Communication(Unicast(ReplicaMessage(GetState(state.view_no, state.op_no, state.replica_no)), primary_no));
               Timeout(ReplicaTimeout(GetStateTimeout(state.valid_timeout, state.op_no), state.replica_no))])
    else
      (state, [])

  (* client timeouts *)

  let on_request_timeout (state : client_state) = 
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

  let on_clientrecovery_timeout (state : client_state) = 
    (* re-send recovery message to non-responsive replicas *)
    let indices = map_falses state.received_clientrecoveryresponses (fun i -> i) in
    let multicast = Multicast(ReplicaMessage(ClientRecovery(state.client_id)), indices) in
    (state, [Communication(multicast); 
             Timeout(ClientTimeout(ClientRecoveryTimeout(state.valid_timeout), state.client_id))])

  (* tying protocol implementation together *)

  (* write functions to project out view number/valid timer and make checks *)
  let on_replica_message msg state = 
    (* perform status and view number checks here *)
    match msg with

    | Request(op, c, s) ->
      if state.status = Normal then
        on_request state op c s
      else 
        (state, [])

    | Prepare(v, m, n, k) -> 
      if state.status <> Normal || v < state.view_no then
        (state, [])
      else if v > state.view_no then
        later_view state v
      else
        let (state, e1s) = on_prepare state v m n k in
        let (state, e2s) = on_commit state v k in
        (state, e2s @ e1s)

    | PrepareOk(v, n, i) -> 
      if state.status <> Normal || v < state.view_no then
        (state, [])
      else if v > state.view_no then
        later_view state v
      else
        on_prepareok state v n i 

    | Commit(v, k) -> 
      if state.status <> Normal || v < state.view_no then
        (state, [])
      else if v > state.view_no then
        later_view state v
      else
        on_commit state v k

    | StartViewChange(v, i) -> 
      if state.status = Recovering || v < state.view_no then
        (state, [])
      else if v > state.view_no then
        notice_viewchange state
      else
        on_startviewchange state v i

    | DoViewChange(v, l, v', n, k, i) -> 
      if state.status = Recovering || v < state.view_no then
        (state, [])
      else if v > state.view_no then
        notice_viewchange state
      else
        on_doviewchange state v l v' n k i

    | StartView(v, l, n, k) -> 
      if state.status = Recovering || v < state.view_no then
        (state, [])
      else
        on_startview state v l n k

    | Recovery(i, x) -> 
      if state.status <> Normal then
        (state, [])
      else
        on_recovery state i x

    | RecoveryResponse(v, x, opt, j) -> 
      if state.status <> Recovering then
        (state, [])
      else
        on_recoveryresponse state v x opt j

    | ClientRecovery(c) -> 
      on_clientrecovery state c

    | GetState(v, n', i) -> 
      if state.status <> Normal || state.view_no <> v then
        (state, [])
      else
        on_getstate state v n' i

    | NewState(v, l, n, k) -> 
      if state.status <> Normal || state.view_no <> v then
        (state, [])
      else
        on_newstate state v l n k

  let on_client_message msg state =
    match msg with 

    | Reply(v, s, res) -> 
      on_reply state v s res

    | ClientRecoveryResponse(v, s, i) -> 
      on_clientrecoveryresponse state v s i

  let on_replica_timeout timeout state = 
    match timeout with

    | HeartbeatTimeout(v, n) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_heartbeat_timeout state n

    | PrepareTimeout(v, k) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_prepare_timeout state k

    | PrimaryTimeout(v, n) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_primary_timeout state n

    | StateTransferTimeout(v, n) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_statetransfer_timeout state n

    | StartViewChangeTimeout(v) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_startviewchange_timeout state

    | DoViewChangeTimeout(v) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_doviewchange_timeout state

    | RecoveryTimeout(v) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_recovery_timeout state

    | GetStateTimeout(v, n) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_getstate_timeout state n

  let on_client_timeout timeout (state : client_state) =
    match timeout with

    | RequestTimeout(v) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_request_timeout state

    | ClientRecoveryTimeout(v) ->
      if state.valid_timeout <> v then 
        (state, [])
      else 
        on_clientrecovery_timeout state

  let init_replicas n_replicas n_clients = 
    let rec init n_r l =
      if n_r < 0 then
        l
      else
        let state = {
          configuration = List.init n_replicas (fun i -> i);
          replica_no = n_r;
          view_no = 0;
          status = Normal;
          op_no = -1;
          log = [];
          commit_no = -1;
          client_table = List.init n_clients (fun _ -> (-1, None));

          queued_prepares = [];
          waiting_prepareoks = [];
          casted_prepareoks = List.init n_replicas (fun _ -> -1);
          highest_seen_commit_no = -1;

          no_startviewchanges = 0;
          received_startviewchanges = List.init n_replicas (fun _ -> false);
          doviewchanges = [];
          last_normal_view_no = 0;

          recovery_nonce = -1;
          no_recoveryresponses = 0;
          received_recoveryresponses = List.init n_replicas (fun _ -> false);
          primary_recoveryresponse = None;

          valid_timeout = 0;
          no_primary_comms = 0;

          mach = StateMachine.create ();
        } in
        init (n_r - 1) (state::l) in
    init (n_replicas - 1) []

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
        } in
        init (n_c - 1) (state::l) in
    init (n_clients - 1) []

  let crash_replica state = 
    let n_replicas = List.length state.configuration in
    let n_clients = List.length state.client_table in
    {
      configuration = state.configuration;
      replica_no = state.replica_no;
      view_no = 0;
      status = Normal;
      op_no = -1;
      log = [];
      commit_no = -1;
      client_table = List.init n_clients (fun _ -> (-1, None));

      queued_prepares = [];
      waiting_prepareoks = [];
      casted_prepareoks = List.init n_replicas (fun _ -> -1);
      highest_seen_commit_no = -1;

      no_startviewchanges = 0;
      received_startviewchanges = List.init n_replicas (fun _ -> false);
      doviewchanges = [];
      last_normal_view_no = 0;

      recovery_nonce = state.recovery_nonce;
      no_recoveryresponses = 0;
      received_recoveryresponses = List.init n_replicas (fun _ -> false);
      primary_recoveryresponse = None;

      valid_timeout = state.valid_timeout;
      no_primary_comms = 0;

      mach = StateMachine.create ();
    }

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
    }

  let recover_replica = begin_recovery
  let recover_client = begin_clientrecovery

  let start_replica state = 
    if is_primary state then
      (state, [Timeout(ReplicaTimeout(HeartbeatTimeout(state.valid_timeout, state.op_no), state.replica_no))])
    else
      (state, [Timeout(ReplicaTimeout(PrimaryTimeout(state.valid_timeout, state.no_primary_comms), state.replica_no))])

  let start_client = start_sending

  let gen_workload state n = {state with operations_to_do = StateMachine.gen_ops n;}

  let index_of_replica state = state.replica_no

  let index_of_client state = state.client_id

end
