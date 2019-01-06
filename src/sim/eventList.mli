module type EventList_type = sig
  type 'event t
  val create: ('event -> 'event -> int) -> 'event t
  val add: 'event t -> 'event -> 'event t
  val add_multi: 'event t -> 'event list -> 'event t
  val pop: 'event t -> ('event * 'event t) option
end

module EventHeap : EventList_type
