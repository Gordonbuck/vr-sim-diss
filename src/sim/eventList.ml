open Core

module type EventList_type = sig
  type 'event t
  val create: ('event -> 'event -> int) -> 'event t
  val add: 'event t -> 'event -> 'event t
  val add_multi: 'event t -> 'event list -> 'event t
  val pop: 'event t -> ('event * 'event t) option
end

module EventHeap : EventList_type = struct

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
