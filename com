#! /usr/bin/env ruby
# frozen_string_literal: true

module Compiler
  class Token
    DIV_WORD_LIST = {
      '{' => { token: :OPEN_BRACE },
      '}' => { token: :CLOSE_BRACE },
      '(' => { token: :OPEN_PARENTHESIS },
      ')' => { token: :CLOSE_PARENTHESIS },
      ';' => { token: :SEMICOLON }
    }.freeze

    RESERVED_WORD = {
      'int' => { token: :INT_KEYWORD },
      'return' => { token: :RETURN_KEYWORD }
    }.freeze

    UNARY_OP = {
      '-' => { token: :NEGATION },
      '~' => { token: :BITWISE_COMPLEMENT },
      '!' => { token: :LOGICAL_NEGATION }
    }.freeze

    BINARY_OP = {
      '+' => { token: :ADDITION },
      '*' => { token: :MULTIPLICATION },
      '/' => { token: :DIVISION }
    }.freeze
  end

  class Program
    attr_accessor :function

    def initialize(function)
      @function = function
    end

    def to_s
      @function.to_s
    end
  end

  class Function
    attr_accessor :name
    attr_accessor :statement

    def initialize(name, statement)
      @name = name
      @statement = statement
    end

    def to_s
      <<~EOS
        func:#{@name}
          #{@statement}
      EOS
    end
  end

  class Statement
    attr_accessor :exp

    def initialize(exp)
      @exp = exp
    end

    def to_s
      "return #{@exp}"
    end
  end

  class UnaryOp
    attr_accessor :operator
    attr_accessor :exp

    def initialize(operator, exp)
      @operator = operator
      @exp = exp
    end

    def to_s
      "#{@operator} #{@exp}"
    end
  end

  class BinaryOp
    attr_accessor :left
    attr_accessor :operator
    attr_accessor :right

    def initialize(left, operator, right)
      @left = left
      @operator = operator
      @right = right
    end

    def to_s
      "(#{@left} #{@operator} #{@right})"
    end
  end

  class Integer
    attr_accessor :value

    def initialize(value)
      @value = value
    end

    def to_s
      @value.to_s
    end
  end

  class Lexer
    def initialize
      @tokens    = []
      @token_buf = ''
    end

    def lex(source_file)
      source_file.each_char do |c|
        detect_token if should_detect?(c)
        @token_buf += c unless c.match(/\s/)
      end

      detect_token
      @tokens
    end

    private

    def should_detect?(char)
      char.match(/\s/)                   ||
        Token::DIV_WORD_LIST[char]       ||
        Token::UNARY_OP[char]            ||
        Token::DIV_WORD_LIST[@token_buf] ||
        Token::UNARY_OP[@token_buf]      ||
        Token::BINARY_OP[@token_buf]
    end

    def detect_token
      buf = \
        Token::DIV_WORD_LIST[@token_buf] ||
        Token::RESERVED_WORD[@token_buf] ||
        Token::UNARY_OP[@token_buf]      ||
        Token::BINARY_OP[@token_buf]     ||
        int_literal(@token_buf)          ||
        identifier(@token_buf)
      @tokens << buf if buf
      @token_buf = ''
    end

    def int_literal(value)
      return nil unless value.match(/[0-9]+/)

      { token: :INTEGER_LITERAL, value: value.to_i }
    end

    def identifier(value)
      return nil if value.empty?

      { token: :INDENTIFIER, value: value }
    end
  end

  class Parser
    def initialize(tokens)
      @tokens = tokens
    end

    def parse
      Program.new(_func)
    end

    private

    def _func
      raise unless @tokens.shift[:token] == :INT_KEYWORD

      name = @tokens.shift
      raise unless name[:token] == :INDENTIFIER

      raise unless @tokens.shift[:token] == :OPEN_PARENTHESIS
      raise unless @tokens.shift[:token] == :CLOSE_PARENTHESIS
      raise unless @tokens.shift[:token] == :OPEN_BRACE

      body = _statement

      raise unless @tokens.shift[:token] == :CLOSE_BRACE

      Function.new(name[:value], body)
    end

    def _statement
      raise unless @tokens.shift[:token] == :RETURN_KEYWORD

      exp = _exp

      raise unless @tokens.shift[:token] == :SEMICOLON

      Statement.new(exp)
    end

    def _exp
      exp = _term
      loop do
        break unless %i[ADDITION NEGATION].include?(@tokens[0][:token])

        operator = @tokens.shift
        right = _term
        exp = BinaryOp.new(exp, operator[:token], right)
      end
      exp
    end

    def _term
      term = _factor
      loop do
        break unless %i[MULTIPLICATION DIVISION].include?(@tokens[0][:token])

        operator = @tokens.shift
        right = _factor
        term = BinaryOp.new(term, operator[:token], right)
      end
      term
    end

    def _factor
      buf = @tokens.shift
      case buf[:token]
      when :OPEN_PARENTHESIS
        exp = _exp
        raise unless @tokens.shift[:token] == :CLOSE_PARENTHESIS

        exp
      when *Token::UNARY_OP.values.map { |u| u[:token] }
        UnaryOp.new(buf[:token], _factor)
      when :INTEGER_LITERAL
        Integer.new(buf[:value])
      end
    end
  end

  class Generator
    def initialize(ast)
      @ast = ast
      @op_stack = []
    end

    def generate
      func_name = @ast.function.name

      make_op_stack(@ast.function.statement.exp, 'eax')

      @op_stack << "    movl $0, %eax\n"

      a = <<~EOS
           .globl #{func_name}
        #{func_name}:
        #{format_op_sack}
            ret
      EOS
    end

    private

    def make_op_stack(exp, reg)
      loop do
        case exp
        when UnaryOp
          unary_op(exp, reg)
          exp = exp.exp
        when BinaryOp
          @op_stack << "    pop %eax\n"
          binary_op(exp)
          break
        when Integer
          integer(exp, reg)
          break
        end
      end
    end

    def integer(exp, reg)
      @op_stack << "    movl $#{exp.value}, %#{reg}\n"
    end

    def unary_op(exp, reg)
      case exp.operator
      when :NEGATION
        @op_stack << "    neg %#{reg}\n"
      when :BITWISE_COMPLEMENT
        @op_stack << "    not %#{reg}\n"
      when :LOGICAL_NEGATION
        @op_stack << "    cmpl $0, %#{reg}\n    movl $0, %#{reg}\n    sete %al\n"
      end
    end

    def binary_op(exp)
      case exp.operator
      when :ADDITION
        @op_stack << <<-EOS
    addl %ecx, %eax
    push %eax
        EOS
      when :NEGATION
        @op_stack << <<-EOS
    subl %ecx, %eax
    push %eax
        EOS
      when :MULTIPLICATION
        @op_stack << <<-EOS
    imul %ecx, %eax
    push %eax
        EOS
      when :DIVISION
        @op_stack << <<-EOS
    movl $0, %edx
    idivl %ecx
    push %eax
        EOS
      end

      if exp.right.is_a?(BinaryOp)
        @op_stack << "    pop %ecx\n"
      else
        make_op_stack(exp.right, 'ecx')
      end

      if exp.left.is_a?(BinaryOp)
        @op_stack << "    pop %ecx\n"
      else
        make_op_stack(exp.left, 'eax')
      end

      binary_op(exp.left) if exp.left.is_a?(BinaryOp)
      binary_op(exp.right) if exp.right.is_a?(BinaryOp)
    end

    def format_op_sack
      @op_stack.reverse.inject('') do |res, st|
        res += st
      end
    end
  end
end

File.open(ARGV[0], 'r') do |f|
  File.open("#{ARGV[0][0..-3]}.s", 'w') do |wf|
    wf.puts Compiler::Generator.new(Compiler::Parser.new(Compiler::Lexer.new.lex(f)).parse).generate
  end
  `gcc -m32 #{ARGV[0][0..-3]}.s -o #{ARGV[0][0..-3]}`
end
