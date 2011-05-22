module Turnsole

## a wrapper around the remote label stuff
class Labels
  ## labels that have special semantics in heliotrope
  HELIOTROPE_SPECIAL_LABELS = Set.new %w(starred unread deleted attachment signed encrypted draft sent)
  ## labels that we attach special semantics to
  TURNSOLE_SPECIAL_LABELS = Set.new %w(spam deleted muted)
  ## all special labels user will be unable to add/remove these via normal label mechanisms.
  RESERVED_LABELS = HELIOTROPE_SPECIAL_LABELS

  def reserved_labels; RESERVED_LABELS end
  def all_labels; @labels + HELIOTROPE_SPECIAL_LABELS end
  def user_mutable_labels; @labels - RESERVED_LABELS end

  def initialize context
    @context = context
    @labels = Set.new
  end

  def load!
    @labels = @context.client.labels
  end

  def prune!
    @labels = @context.client.prune_labels!
  end
end
end
