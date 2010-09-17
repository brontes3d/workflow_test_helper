require File.expand_path(File.dirname(__FILE__) + "/xmpp_test_helper")
require File.expand_path(File.dirname(__FILE__) + "/xmpp_device")

require 'active_support/test_case'
require 'action_controller/test_case'
require 'action_controller/test_process'
require 'action_controller/integration'

class WorkflowTestHelperBase

  class UploadedFile < ActionController::TestUploadedFile
    cattr_accessor :max_file_size
    @@max_file_size = 2097152
    # @@max_file_size = 0
    
    # The filename, *not* including the path, of the "uploaded" file
    attr_reader :original_filename

    # The content type of the "uploaded" file
    attr_reader :content_type

    def initialize(path, content_type = Mime::TEXT, binary = false)
      raise "#{path} file does not exist" unless File.exist?(path)
      @content_type = content_type
      @original_filename = path.sub(/^.*#{File::SEPARATOR}([^#{File::SEPARATOR}]+)$/) { $1 }
      @tempfile = Tempfile.new(@original_filename)
      @tempfile.binmode if binary
      
      if UploadedFile.max_file_size > 0
        File.open(path, "r") do |r|
          File.open(@tempfile.path, "w+") do |w|
            w.write(r.read(UploadedFile.max_file_size))
          end
        end
      else
        FileUtils.copy_file(path, @tempfile.path)
      end
      
    end

    def path #:nodoc:
      @tempfile.path
    end

    alias local_path path

    def method_missing(method_name, *args, &block) #:nodoc:
      @tempfile.send!(method_name, *args, &block)
    end
  end

  def self.ensure_movers_is_defined
    self.class_eval do
      cattr_accessor :movers
    end
    self.movers ||= []
  end
  
  def self.documentation_for_states
    to_return = ""
    ensure_movers_is_defined
    self.movers.each do |mover|
      to_return += "\n*#{mover.from}* to *#{mover.to}* \n"
      mover.steps.each do |s|
        description, step = s
        to_return += "1. #{description}\n"
      end
    end
    to_return
  end
  
  #implementation details...
  class StateMover
    attr_accessor :from, :to, :outputs, :inputs, :runner, :from_test, :setup_method, :output_proc, :steps
    def initialize(from, to, &block)
      self.from = from
      self.to = to
      self.outputs = false
      self.setup_method = :with_no_setup
      self.steps = []
      self.instance_eval(&block)
    end
    def setup(setup)
      self.setup_method = setup
    end
    def expects_outputs(*args, &block)
      self.outputs = args
      self.output_proc = block || raise(ArgumentError, "Expected a block to expects_outputs #{args.inspect}")
    end
    def require_inputs(*args, &block)
      self.inputs = args
      self.runner = block || raise(ArgumentError, "Expected a block to require_inputs #{args.inspect}")
    end
    def step(description, &block)
      self.steps << [description, block]
    end
    def run(helper, inputs_given, log_steps = true)
      unless inputs_given
        raise "No :inputs given!"
      end
      inputs_to_use = []
      self.inputs.each do |i|
        inputs_to_use << inputs_given[i]
      end
      # puts "Going from '#{from}' to '#{to}'" if log_steps
      result = helper.send(self.setup_method) do
        
        self.from_test.instance_eval do
          class << self
            cattr_accessor :workflow_test_helper_runner
            self
          end
        end.workflow_test_helper_runner = self.runner        
        self.from_test.instance_eval do
          class << self
            define_method(:workflow_test_helper_runner, &self.workflow_test_helper_runner)
            # def run_the_workflow_test_helper_runner(*args)
            #   session = open_session do             
            #     self.workflow_test_helper_runner(*args)
            #   end
            #   session = nil
            #   post_request_params = nil
            #   request = nil
            #   response = nil
            #   @result = nil
            #   @request = nil
            #   @response = nil
            #   @integration_session = nil
            #   GC.start
            # end
          end
        end
        # self.from_test.run_the_workflow_test_helper_runner(*inputs_to_use)
        self.from_test.workflow_test_helper_runner(*inputs_to_use)
        
        # the_runner.call(inputs_to_use)
        
        self.steps.each_with_index do |s, index|
          description, step = s
          # puts "Step #{index+1} : #{description}" if log_steps
          self.from_test.instance_eval(&step)
        end
        # (output_proc || Proc.new{ nil }).call
        self.from_test.instance_eval(&(output_proc || Proc.new{ nil }))
      end
      # puts "Completed, result : #{result.inspect}" if log_steps
      result
    end
  end
  
  
  def self.to_move(from, to, &block)
    ensure_movers_is_defined
    self.movers << StateMover.new(from, to, &block)
  end
  def initialize(from_test)
    @from_test = from_test
  end
  def move(params, log_steps = false)
    mover_chain = self.chain_movers([], params[:from], params[:to])    
    inputs = params[:inputs]
    outputs = {}
    mover_chain.each do |mover|
      # puts "running from inputs: " + inputs.inspect
      mover.from_test = @from_test      
      result = mover.run(self, inputs, log_steps)
      if mover.outputs
        inputs.merge!(result)
        outputs.merge!(result)
      end
      # puts "outputs: " + outputs.inspect
    end
    return outputs
  end
  def chain_movers(chain_so_far, start_state, end_state)
    self.class.ensure_movers_is_defined
    self.class.movers.each do |mover|
      if mover.from.to_s == start_state.to_s
        if mover.to.to_s == end_state.to_s
          return (chain_so_far + [mover])
        else
          return chain_movers((chain_so_far + [mover]), mover.to, end_state)
        end
      end
    end
    raise "couldn't find a state mover to go from: #{start_state} to: #{end_state}"    
  end
  
  
  #setup methods
    
  def with_no_setup
    yield
  end
  
  def with_messaging_on
    previous_value_for_disable_message_sending = BrontesMessageOut.disable_message_sending
    BrontesMessageOut.disable_message_sending = false
    run_xmpp_listener
    result = yield
    stop_xmpp_listener
    BrontesMessageOut.disable_message_sending = previous_value_for_disable_message_sending
    result
  end
  
end