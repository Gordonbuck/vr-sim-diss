type t
type span
val compare: t -> t -> int
val diff: t -> t -> span
val inc: t -> span -> t
val span_of_float: float -> span
val t_of_float: float -> t
