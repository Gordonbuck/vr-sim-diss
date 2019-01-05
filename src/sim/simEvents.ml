open Core

module Event = struct
  
  type ('time, 'id, 'replica, 'client) t =
    | ReplicaEvent of 'time * 'id * ('time, 'id, 'replica, 'client) replica_comp
    | ClientEvent of 'time * 'id * ('time, 'id, 'replica, 'client) client_comp
    | SimulationEvent of 'time * 'id * sim_comp
  and ('time, 'id, 'replica, 'client) replica_comp = 'replica -> 'replica * ('time, 'id, 'replica, 'client) t list
  and ('time, 'id, 'replica, 'client) client_comp = 'client -> 'client * ('time, 'id, 'replica, 'client) t list
  and sim_comp = Crash | Recover

  let time_of event = 
    match event with
    | ReplicaEvent(t, _, _)
    | ClientEvent(t, _, _)
    | SimulationEvent(t, _, _) -> t

  let compare e1 e2 = 
    if time_of e1 > time_of e2 then 1
    else if time_of e1 < time_of e2 then -1
    else 0

end

module type EventList_type = sig
  type 'event t
  val create: ('event -> 'event -> int) -> 'event t
  val add: 'event t -> 'event -> 'event t
  val pop: 'event t -> ('event * 'event t) option
end

module EventList : EventList_type = struct

  type 'event t = { heap : 'event Fheap.t; }

  let create cmp = { heap = Fheap.create cmp }

  let add el e = { heap = Fheap.add el.heap e }

  let rec add_multi el l = 
    match l with
    | [] -> el
    | e::l -> add_multi (add el e) l

  let pop el = 
    let opt = Fheap.pop el.heap in
    match opt with
    | None -> None
    | Some(e, heap) -> Some(e, { heap = heap })

end
