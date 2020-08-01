package Parser;
use strict;
use warnings;
use Expr;
use Stmt;
use TokenType;

sub new {
  my ($class, $args) = @_;
  return bless {
    tokens => ($args->{tokens} || die 'requires an arrayref of tokens'),
    repl   => $args->{repl},
    errors => [],
    current=> 0,
  }, $class;
}

sub tokens { $_[0]->{tokens} }
sub errors :lvalue { $_[0]->{errors} }
sub current :lvalue { $_[0]->{current} }

sub parse {
  my $self = shift;
  my @statements;
  while (!$self->is_at_end) {
    push @statements, $self->declaration;
  }
  return \@statements;
}

sub declaration {
  my $self = shift;
  my $dec = eval {
    if ($self->check(FUN) && $self->check(IDENTIFIER, 1)) {
      $self->advance;
      $self->function_stmt('function');
    }
    elsif ($self->match(VAR)) { $self->var_declaration }
    else { $self->statement }
  };
  unless ($@) {
    return $dec;
  }
  $self->synchronize;
  return undef;
}

sub statement {
  my $self = shift;
  if ($self->match(FOR)) {
    return $self->for_statement;
  }
  if ($self->match(BREAK)) {
    return $self->break_statement;
  }
  if ($self->match(IF)) {
    return $self->if_statement;
  }
  if ($self->match(WHILE)) {
    return $self->while_statement;
  }
  if ($self->match(LEFT_BRACE)) {
    return Stmt::Block->new({statements => $self->block});
  }
  if ($self->match(PRINT)) {
    return $self->print_statement;
  }
  if ($self->match(RETURN)) {
    return $self->return_statement;
  }
  return $self->expression_statement;
}

sub for_statement {
  my $self = shift;
  $self->consume(LEFT_PAREN, "Expect '(' after 'for'.");

  my $initializer;
  if ($self->match(SEMICOLON)) {
    $initializer = undef;
  }
  elsif ($self->match(VAR)) {
    $initializer = $self->var_declaration;
  }
  else {
    $initializer = $self->expression_statement;
  }

  my $condition = Expr::Literal->new({value => 1});
  if (!$self->check(SEMICOLON)) {
    $condition = $self->expression;
  }
  $self->consume(SEMICOLON, 'Expect ";" after loop condition');

  my $increment = undef;
  if (!$self->check(RIGHT_PAREN)) {
    $increment = $self->expression;
  }
  $self->consume(RIGHT_PAREN, 'Expect ")" after for clauses');

  my $body = $self->statement;
  if ($increment) {
    $body = Stmt::Block->new({statements =>
        [$body, Stmt::Expression->new({expression => $increment})]});
  }
  $body = Stmt::While->new({condition => $condition, body => $body});

  if ($initializer) {
    $body = Stmt::Block->new({statements => [$initializer, $body]});
  }

  return $body;
}

sub if_statement {
  my $self = shift;
  $self->consume(LEFT_PAREN, "Expect '(' after 'if'.");
  my $condition = $self->expression;
  $self->consume(RIGHT_PAREN, "Expect ')' after condition.");

  my $then_branch = $self->statement;
  my $else_branch = undef;
  if ($self->match(ELSE)) {
    $else_branch = $self->statement;
  }
  return Stmt::If->new({
      condition   => $condition,
      then_branch => $then_branch,
      else_branch => $else_branch,
    });
}

sub break_statement {
  my $self = shift;
  $self->error($self->previous, 'Can only break out of loops.')
    unless $self->{looping};
  $self->consume(SEMICOLON, 'Expect ";" after "break".');
  return Stmt::Break->new({});
}

sub var_declaration {
  my $self = shift;
  my $name = $self->consume(IDENTIFIER, "Expect variable name.");
  my $init = undef;
  if ($self->match(EQUAL)) {
    $init = $self->expression;
  }
  $self->consume(SEMICOLON, 'Expect ";" after variable declaration.');
  return Stmt::Var->new({name => $name, initializer => $init});
}

sub while_statement {
  my $self = shift;
  $self->consume(LEFT_PAREN, "Expect '(' after 'while'.");
  my $condition = $self->expression;
  $self->consume(RIGHT_PAREN, "Expect ')' after condition.");
  $self->{looping}++;
  my $while = Stmt::While->new({
      condition => $condition,
      body      => $self->statement,
    });
  $self->{looping}--;
  return $while;
}

sub expression_statement {
  my $self = shift;
  my $value = $self->expression;
  $self->consume(SEMICOLON, 'Expect ";" after value.');
  return Stmt::Expression->new({expression => $value});
}

sub function_stmt {
  my ($self, $kind) = @_;
  my $name = $self->consume(IDENTIFIER, "Expect $kind name.");
  my ($parameters, $body) = $self->parse_function($kind);
  return Stmt::Function->new({
      name   => $name,
      params => $parameters,
      body   => $body,
    });
}

sub function_expr {
  my ($self) = @_;
  my ($parameters, $body) = $self->parse_function('anonymous function');
  return Expr::Function->new({
      params => $parameters,
      body   => $body,
    });
}

sub parse_function {
  my ($self, $kind) = @_;
  $self->consume(LEFT_PAREN, "Expect '(' after $kind declaration.");
  my @parameters;
  if (!$self->check(RIGHT_PAREN)) {
    do {
      if (@parameters >= 255) {
        $self->error($self->peek, "Cannot have more than 255 parameters.");
      }

      push @parameters, $self->consume(IDENTIFIER, "Expect parameter name.");
    } while ($self->match(COMMA));
  }
  $self->consume(RIGHT_PAREN, "Expect ')' after parameters.");

  $self->consume(LEFT_BRACE, "Expect '{' before $kind body.");
  $self->{functioning}++;
  my $body = $self->block;
  $self->{functioning}--;
  return \@parameters, $body;
}

sub block {
  my $self = shift;
  my @statements;
  while (!$self->check(RIGHT_BRACE) && !$self->is_at_end) {
    push @statements, $self->declaration;
  }
  $self->consume(RIGHT_BRACE, "Expect '}' after block.");
  return \@statements;
}

sub print_statement {
  my $self = shift;
  my $value = $self->expression;
  $self->consume(SEMICOLON, 'Expect ";" after value.');
  return Stmt::Print->new({expression => $value});
}

sub return_statement {
  my $self = shift;
  my $keyword = $self->previous;
  $self->error($keyword, 'Can only return from functions.')
    unless $self->{functioning};
  my $value = $self->check(SEMICOLON) ? undef : $self->expression;
  $self->consume(SEMICOLON, 'Expect ";" after return value.');
  return Stmt::Return->new({keyword => $keyword, value => $value});
}

sub assignment {
  my $self = shift;
  my $expr = $self->_or;
  if ($self->match(EQUAL)) {
    my $equals = $self->previous;
    my $value = $self->assignment;
    if (ref $expr eq 'Expr::Variable') {
      return Expr::Assign->new({name => $expr->name, value => $value});
    }
    $self->error($equals, 'Invalid assignment target');
  }
  return $expr;
}

sub _or {
  my $self = shift;
  my $expr = $self->_and;

  while ($self->match(OR)) {
    $expr = Expr::Logical->new({
        left => $expr,
        operator => $self->previous,
        right => $self->_and,
      });
  }
  return $expr;
}

sub _and {
  my $self = shift;
  my $expr = $self->equality;

  while ($self->match(AND)) {
    $expr = Expr::Logical->new({
        left => $expr,
        operator => $self->previous,
        right => $self->_and,
      });
  }
  return $expr;
}

sub expression { shift->assignment }

sub equality {
  my $self = shift;
  my $expr = $self->comparison;
  while ($self->match(BANG_EQUAL, EQUAL_EQUAL)) {
    $expr = Expr::Binary->new({
        left     => $expr,
        operator => $self->previous,
        right    => $self->comparison,
    });
  }
  return $expr;
}

sub comparison {
  my $self = shift;
  my $expr = $self->addition;
  while ($self->match(GREATER, GREATER_EQUAL, LESS, LESS_EQUAL)) {
    $expr = Expr::Binary->new({
        left     => $expr,
        operator => $self->previous,
        right    => $self->addition,
    });
  }
  return $expr;
}

sub addition {
  my $self = shift;
  my $expr = $self->multiplication;
  while ($self->match(MINUS, PLUS)) {
    $expr = Expr::Binary->new({
        left     => $expr,
        operator => $self->previous,
        right    => $self->multiplication,
    });
  }
  return $expr;
}

sub multiplication {
  my $self = shift;
  my $expr = $self->unary;
  while ($self->match(SLASH, STAR)) {
    $expr = Expr::Binary->new({
        left     => $expr,
        operator => $self->previous,
        right    => $self->unary,
    });
  }
  return $expr;
}

sub unary {
  my $self = shift;
  if ($self->match(BANG, MINUS)) {
    my $expr = Expr::Unary->new({
        operator => $self->previous,
        right    => $self->unary,
    });
    return $expr;
  }
  return $self->call;
}

sub call {
  my $self = shift;
  my $expr = $self->primary;
  while (1) {
    if ($self->match(LEFT_PAREN)) {
      $expr = $self->finish_call($expr);
    }
    else {
      last;
    }
  }
  return $expr;
}

sub finish_call {
  my ($self, $callee) = @_;
  my @args;
  if (!$self->check(RIGHT_PAREN)) {
    do {
      $self->error($self->peek, 'Cannot have more than 255 arguments.')
        if @args >= 255;
      push @args, $self->expression;
    } while ($self->match(COMMA));
  }
  my $paren = $self->consume(RIGHT_PAREN, 'Expect ")" after arguments.');
  return Expr::Call->new({
      arguments => \@args,
      callee    => $callee,
      paren     => $paren,
  });
}

sub primary {
  my $self = shift;
  if ($self->match(FALSE)) {
    return Expr::Literal->new({value => undef});
  }
  elsif ($self->match(TRUE)) {
    return Expr::Literal->new({value => 1});
  }
  elsif ($self->match(NIL)) {
    return Expr::Literal->new({value => undef});
  }
  elsif ($self->match(NUMBER, STRING)) {
    return Expr::Literal->new({value => $self->previous->{literal}});
  }
  elsif ($self->match(IDENTIFIER)) {
    return Expr::Variable->new({name => $self->previous});
  }
  elsif ($self->match(LEFT_PAREN)) {
    my $expr = $self->expression;
    $self->consume(RIGHT_PAREN, 'Expect ")" after expression.');
    return Expr::Grouping->new({expression => $expr});
  }
  elsif ($self->match(FUN)) {
    return $self->function_expr;
  }
  $self->error($self->peek, 'Expect expression');
}

sub match {
  my ($self, @types) = @_;
  for my $t (@types) {
    if ($self->check($t)) {
      $self->advance;
      return 1;
    }
  }
  return undef;
}

sub consume {
  my ($self, $type, $msg) = @_;
  return $self->advance if $self->check($type);
  $self->error($self->peek, $msg);
}

sub check {
  my ($self, $type, $offset) = @_;
  return $self->is_at_end ? undef : $self->peek($offset)->{type} == $type;
}

sub advance {
  my $self = shift;
  $self->current++ unless $self->is_at_end;
  return $self->previous;
}

sub is_at_end { shift->peek->{type} == EOF }

sub peek {
  my ($self, $offset) = @_;
  return $self->tokens->[ $self->current + ($offset//0) ];
}

sub previous {
  my $self = shift;
  return $self->tokens->[ $self->current - 1];
}

sub error {
  my ($self, $token, $msg) = @_;
  push $self->errors->@*, [$token, $msg];
  die $msg;
}

sub synchronize {
  my $self = shift;
  $self->advance;
  while (!$self->is_at_end) {
    return if $self->previous->{type} == SEMICOLON;
    my $next = $self->peek;
    return if grep { $next == $_ } CLASS,FUN,VAR,FOR,IF,WHILE,PRINT,RETURN;
    $self->advance;
  }
}

1;
