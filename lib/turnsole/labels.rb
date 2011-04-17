module Turnsole

## a wrapper around the remote label stuff
class Labels
  ## labels that have special semantics in heliotrope
  HELIOTROPE_SPECIAL_LABELS = Set.new %w(starred unread deleted attachment signed encrypted draft sent)
  ## labels that we attach special semantics to
  TURNSOLE_SPECIAL_LABELS = Set.new %w(spam deleted killed)
  ## all special labels user will be unable to add/remove these via normal label mechanisms.
  RESERVED_LABELS = HELIOTROPE_SPECIAL_LABELS + TURNSOLE_SPECIAL_LABELS

  def reserved_labels; RESERVED_LABELS end
  def all_labels; @labels end
  def user_mutable_labels; @labels - RESERVED_LABELS end

  def initialize context
    @context = context
    @labels = Set.new
  end

  def load!
    @context.client.labels { |labels| @labels = Set.new labels }
  end

  def prune!
    @context.client.prune_labels! { |labels| @labels = Set.new labels }
  end
end
end
