package Resolver;
use strict;
use warnings;
use enum qw(FUNCTION NONE);

sub new {
  my ($class, $interpreter) = @_;
  return bless {
    current_function => NONE,
    interpreter      => $interpreter,
    scopes           => [],
  }, $class;
}

sub current_function :lvalue { $_[0]->{current_function} }
sub interpreter { $_[0]->{interpreter} }
sub scopes { $_[0]->{scopes} }

sub visit_block_stmt {
  my ($self, $stmt) = @_;
  $self->begin_scope;
  $self->resolve($stmt->statements);
  $self->end_scope;
  return undef;
}

sub visit_expression_stmt {
  my ($self, $stmt) = @_;
  $self->resolve($stmt->expression);
  return undef;
}

sub visit_if_stmt {
  my ($self, $stmt) = @_;
  $self->resolve($stmt->condition);
  $self->resolve($stmt->then_branch);
  if ($stmt->else_branch) {
    $self->resolve($stmt->else_branch);
  }
  return undef;
}

sub visit_print_stmt {
  my ($self, $stmt) = @_;
  $self->resolve($stmt->expression);
  return undef;
}

sub visit_return_stmt {
  my ($self, $stmt) = @_;
  if ($self->current_function != FUNCTION) {
    Lox::error($stmt->keyword, 'Cannot return from top-level code.');
  }
  if ($stmt->value) {
    $self->resolve($stmt->value);
  }
  return undef;
}

sub visit_function_stmt {
  my ($self, $stmt) = @_;
  $self->declare($stmt->name);
  $self->define($stmt->name);
  $self->resolve_function($stmt, FUNCTION);
  return undef;
}

sub resolve {
  my ($self, $stmt_or_expr) = @_;
  if (ref $stmt_or_expr ne 'ARRAY') {
    $stmt_or_expr = [$stmt_or_expr];
  }
  $_->accept($self) for (@$stmt_or_expr);
  $self->check_all_local_variables_used;
  return undef;
}

sub check_all_local_variables_used {
  my $self = shift;
  for my $local (values $self->interpreter->locals->%*) {
    next if $local->{accessed};
    Lox::error($local->{expr}->name, 'Local variable is never used.');
  }
}

sub resolve_function {
  my ($self, $stmt, $type) = @_;
  my $enclosing_function = $self->current_function;
  $self->current_function = $type;
  $self->begin_scope;
  for my $param ($stmt->params->@*) {
    $self->declare($param);
    $self->define($param);
  }
  $self->resolve($stmt->body);
  $self->end_scope;
  $self->current_function = $enclosing_function;
}

sub begin_scope {
  my $self = shift;
  push $self->scopes->@*, {};
  return undef;
}

sub end_scope {
  my $self = shift;
  pop $self->scopes->@*;
  return undef;
}

sub visit_var_stmt {
  my ($self, $stmt) = @_;
  $self->declare($stmt->name);
  if (my $init = $stmt->initializer) {
    $self->resolve($init);
  }
  $self->define($stmt->name);
  return undef;
}

sub visit_while_stmt {
  my ($self, $stmt) = @_;
  $self->resolve($stmt->condition);
  $self->resolve($stmt->body);
  return undef;
}

sub visit_assign {
  my ($self, $expr) = @_;
  $self->resolve($expr->value);
  $self->resolve_local($expr, $expr->name);
  return undef;
}

sub visit_binary {
  my ($self, $expr) = @_;
  $self->resolve($expr->left);
  $self->resolve($expr->right);
  return undef;
}

sub visit_call {
  my ($self, $expr) = @_;
  $self->resolve($expr->callee);
  for my $argument ($expr->arguments->@*) {
    $self->resolve($argument);
  }
  return undef;
}

sub visit_grouping {
  my ($self, $expr) = @_;
  $self->resolve($expr->expression);
  return undef;
}

sub visit_literal { undef }

sub visit_logical {
  my ($self, $expr) = @_;
  $self->resolve($expr->left);
  $self->resolve($expr->right);
  return undef;
}

sub visit_unary {
  my ($self, $expr) = @_;
  $self->resolve($expr->right);
  return undef;
}

sub declare {
  my ($self, $name_token) = @_;
  return undef unless $self->scopes->@*;

  my $scope = $self->scopes->[-1];
  if (exists $scope->{$name_token->lexeme}) {
    Lox::error($name_token,
        "Variable with this name already declared in this scope.");
  }

  return $self->scopes->[-1]{$name_token->lexeme} = 0;
}

sub define {
  my ($self, $name_token) = @_;
  return undef unless $self->scopes->@*;
  return $self->scopes->[-1]{$name_token->lexeme} = 1;
}

sub visit_variable {
  my ($self, $expr) = @_;
  my $value = $self->scopes->@* && $self->scopes->[-1]{$expr->name->lexeme};
  if (defined $value && $value == 0) {
    Lox::error($expr->name,
      'Cannot read local variable in its own initializer.');
  }
  $self->resolve_local($expr, $expr->name);
  return undef;
}

sub resolve_local {
  my ($self, $expr, $name_token) = @_;
  for (my $i = $#{$self->scopes}; $i >= 0; $i--) {
    if (exists $self->scopes->[$i]{$name_token->lexeme}) {
      $self->interpreter->resolve($expr, $#{$self->scopes} - $i);
      return;
    }
  }
  # not found assume it is global
}

1;