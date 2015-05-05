module type DATA =
sig
(** Compute running statitics using recurrence equations. *)
type t = Oml.Running.t = { size : int         (** Number of observations. *)
         ; last : float       (** Last observation. *)
         ; max : float        (** Maxiumum. *)
         ; min : float        (** Minimum. *)
         ; sum : float        (** Sum . *)
         ; sum_sq : float     (** Sum of squares. *)
         ; mean : float       (** Mean. *)
         ; var : float        (** _Unbiased_ variance *)
} [@@deriving show]
end

module type S =
sig
  module T : DATA
  type t = T.t
  val create : cnt:int -> exp:float -> t
  val count : t -> int
  val expect : t -> float
  val var : t -> float
  val max : t -> float
  val min : t -> float
  val sum : t -> float
  val last : t ->  float

  val update : cnt:int -> exp:float -> update_rule:'a Update_rules.Update_fn.t
    -> ?prior_count:('a -> int) -> ?prior_exp:('a -> float) -> 'a -> t option -> t
end

module Make(Data:DATA) : S with module T = Data
