open Core
open VR_State

let notice_viewchange state trace_event = 
  let state = if status state <> ViewChange then reset_monitor state else state in
  let state = update_monitor state `Send_Startviewchange in
  let state = set_status state ViewChange in
  let state = increment_view_no state in
  let trace = ReplicaTrace(int_of_index (replica_no state), n_replicas state, state, trace_event, "broadcasting start view change") in
  (state, [Communication(Broadcast(ReplicaMessage(StartViewChange(view_no state, replica_no state))));
           Timeout(ReplicaTimeout(StartViewChangeTimeout(valid_timeout state), int_of_index (replica_no state)))], trace)

let on_startviewchange state v i =
  let trace_event = "start view change received" in
  if v > (view_no state) && (status state) <> Recovering then
    notice_viewchange state trace_event
  else if v = (view_no state) && (status state) = ViewChange then
    let received_startviewchange = received_startviewchange state i in
    if received_startviewchange then
      (* already received a startviewchange from this replica*)
      let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "already received start view change from this replica, re-sending") in
      (state, [Communication(Unicast(ReplicaMessage(StartViewChange(view_no state, replica_no state)), int_of_index i))], trace)
    else
      let state = log_startviewchange state i in
      let state = update_monitor state `Receive_Startviewchange in
      let f = (quorum state) - 1 in
      let primary_no = primary_no state in
      let no_startviewchanges = no_received_startviewchanges state in
      let (n_packets, events, trace_details) = 
        if (no_startviewchanges = f) then
          let state = update_monitor state `Send_Doviewchange in
          let msg = DoViewChange(view_no state, log state, last_normal_view_no state, op_no state, commit_no state, replica_no state) in
          let comm = Unicast(ReplicaMessage(msg), int_of_index primary_no) in
          (1, [Communication(comm); Timeout(ReplicaTimeout(DoViewChangeTimeout(valid_timeout state), int_of_index (replica_no state)));
               Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))],
           "sending do view change to new primary")
        else (0, [], "waiting on more start view changes") in
      let trace = ReplicaTrace(int_of_index (replica_no state), n_packets, state, trace_event, trace_details) in
      (state, events, trace)
  else if v = (view_no state) && (status state) = Normal then
    let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "already recovered, re-sending start view change") in
    (state, [Communication(Unicast(ReplicaMessage(StartViewChange(view_no state, replica_no state)), int_of_index i))], trace)
  else
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "old view number / recovering") in
    (state, [], trace)

let on_doviewchange state v l v' n k i =
  let trace_event = "received do view change" in
  if (status state) = Recovering || v < (view_no state) then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "old view number / recovering") in
    (state, [], trace)
  else if v > (view_no state) then
    notice_viewchange state trace_event
  else if (status state) = Normal then
    (* recovered, re-send startview message *)
    let trace = ReplicaTrace(int_of_index (replica_no state), 1, state, trace_event, "already recovered, resend start view") in
    (state, [Communication(Unicast(ReplicaMessage(StartView(view_no state, log state, op_no state, commit_no state)), int_of_index i))], trace)
  else
    let received_doviewchange = received_doviewchange state i in
    if received_doviewchange then
      (* already received a doviewchange message from this replica *)
      let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "already received do view change from this replica") in
      (state, [], trace)
    else  
      let state = log_doviewchange state v l v' n k i in
      let state = update_monitor state `Receive_Doviewchange in
      let no_doviewchanges = no_received_doviewchanges state in
      let q = quorum state in
      if (no_doviewchanges = q) then
        let state = update_monitor state `Send_Startview in
        let (state, k) = process_doviewchanges state in
        let state = set_status state Normal in
        let state = become_primary state in
        let (state, replies) = commit state k in
        let state = if (List.length replies > 0) then update_monitor state `Send_Reply else state in
        let state = reset_monitor state in
        let events = List.map replies (fun c -> Communication(c)) in
        let timeout = ReplicaTimeout(HeartbeatTimeout(valid_timeout state, op_no state), int_of_index (replica_no state)) in
        let comm = Broadcast(ReplicaMessage(StartView(view_no state, log state, op_no state, commit_no state))) in
        let trace = ReplicaTrace(int_of_index (replica_no state), n_replicas state, state, trace_event, "broadcast start view") in
        (state, Timeout(timeout)::Communication(comm)::events, trace)
      else
        let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "waiting on more do view changes") in
        (state, [], trace)

let on_startview state v l n k = 
  let trace_event = "received start view" in
  if (status state) = Recovering || v < (view_no state) || (v = (view_no state) && (status state) <> ViewChange) then
    let trace = ReplicaTrace(int_of_index (replica_no state), 0, state, trace_event, "old view number / recovering / already in view") in
    (state, [], trace)
  else
    let state = update_monitor state `Receive_Startview in
    let state = set_view_no state v in
    let state = set_op_no state n in
    let state = set_log state l in
    let state = set_status state Normal in
    let state = become_replica state in
    let (state, _) = commit state k in
    let (n_packets, events, trace_details) = 
      if ((commit_no state) < (op_no state)) then
        (1, [Communication(Unicast(ReplicaMessage(PrepareOk(view_no state, op_no state, replica_no state)), int_of_index (primary_no state)))],
         "started view, sending prepareok for noncommitted operations")
      else
        (0, [], "started view") in
    let state = if ((commit_no state) < (op_no state)) then update_monitor state `Send_Prepareok else state in
    let state = reset_monitor state in
    let trace = ReplicaTrace(int_of_index (replica_no state), n_packets, state, trace_event, trace_details) in
    (state, Timeout(ReplicaTimeout(PrimaryTimeout(valid_timeout state, no_primary_comms state), int_of_index (replica_no state)))::events, trace)


