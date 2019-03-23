open Core
open ClientState
open ReplicaState
open VR_Events
open VR_Utils

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
  if v > state.view_no && state.status <> Recovering then
    notice_viewchange state
  else if v = state.view_no && state.status = ViewChange then
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
  else
    (state, [])

let on_doviewchange state v l v' n k i =
  if state.status = Recovering || v < state.view_no then
    (state, [])
  else if v > state.view_no then
    notice_viewchange state
  else if state.status = Normal then
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
        let (_, mach, client_table, replies) = commit state ((List.length state.log) - 1 - commit_no) in
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
  if state.status = Recovering || v < state.view_no || (v = state.view_no && state.status <> ViewChange) then
    (state, [])
  else
    let view_no = v in
    let log = l in
    let op_no = n in
    let status = Normal in 
    let commit_no = k in
    let (_, mach, client_table, _) = commit state ((List.length state.log) - 1 - commit_no) in
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
