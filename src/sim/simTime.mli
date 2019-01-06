type t
type span
val compare: t -> t -> int
val diff: t -> t -> span
val inc: t -> span -> t
val span_of_int: int -> span
val t_of_int: int -> t
