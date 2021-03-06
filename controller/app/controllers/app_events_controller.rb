##
#@api REST
# Application management APIs
class AppEventsController < BaseController
  include RestModelHelper
  before_filter :get_domain, :get_application
  ##
  # API to perform manage an application
  # 
  # URL: /domains/:domain_id/applications/:application_id/events
  #
  # Action: POST
  # @param [String] event Application event to create. Supported types include
  #   * start: Start all application cartridges
  #   * stop: Stop all application cartridges
  #   * force-stop: For all application cartridges to stop
  #   * restart: Restart all application cartridges
  #   * add-alias: Associate a new DNS alias with the application. Requires *alias* parameter
  #   * remove-alias: Unassociate a DNS alias from the application. Requires *alias* parameter
  #   * scale-up: Trigger a scale-up for the web framework cartridge
  #   * scale-down: Trigger a scale-down for the web framework cartridge
  #   * thread-dump: Retrieve a list of all threads running on all gears of the application
  #   * tidy: Trigger garbage collection and cleanup of logs, git revisions
  #   * reload: Restart all application cartridges
  # @param [String] alias DNS alias for the application. Only applicable to add-alias and remove-alias events
  # 
  # @return [RestReply<RestApplication>] Application object on which the event operates and messages returned for the event.
  def create
    event = params[:event].presence
    server_alias = params[:alias].presence

    return render_error(:unprocessable_entity, "Alias must be specified for adding or removing application alias.", 126,
                        "event") if ['add-alias', 'remove-alias'].include?(event) && (server_alias.nil? or server_alias.to_s.empty?)
    return render_error(:unprocessable_entity, "Reached gear limit of #{@cloud_user.max_gears}", 104) if (event == 'scale-up') && (@cloud_user.consumed_gears >= @cloud_user.max_gears)
    
    if @application.quarantined && ['scale-up', 'scale-down'].include?(event)
      return render_upgrade_in_progress            
    end
      

    msg = "Added #{event} to application #{@application.name}"
    begin
      case event
        when "start"
          r = @application.start
          msg = "Application #{@application.name} has started"
        when "stop"
          r = @application.stop
          msg = "Application #{@application.name} has stopped"
        when "force-stop"
          r = @application.stop(nil, true)
          msg = "Application #{@application.name} has forcefully stopped"
        when "restart"
          r = @application.restart
          msg = "Application #{@application.name} has restarted"
        when "show-port", "expose-port", "conceal-port"
          return render_error(:gone, "This event (#{event}) is no longer supported.", 112)
        when "add-alias"
          r = @application.add_alias(server_alias)
          msg = "Application #{@application.name} has added alias"
        when "remove-alias"
          begin
            r = @application.remove_alias(server_alias)
          rescue Mongoid::Errors::DocumentNotFound
            return render_error(:not_found, "Alias #{server_alias} not found for application #{@application.name}", 173, "#{event.sub('-', '_').upcase}_APPLICATION")
          end
          msg = "Application #{@application.name} has removed alias"
        when "scale-up"
          web_framework_component_instance = @application.component_instances.select{ |c| CartridgeCache.find_cartridge(c.cartridge_name,@application).categories.include?("web_framework") }.first
          r = @application.scale_by(web_framework_component_instance.group_instance_id, 1)
          msg = "Application #{@application.name} has scaled up"
        when "scale-down"
          web_framework_component_instance = @application.component_instances.select{ |c| CartridgeCache.find_cartridge(c.cartridge_name,@application).categories.include?("web_framework") }.first
          r = @application.scale_by(web_framework_component_instance.group_instance_id, -1)
          msg = "Application #{@application.name} has scaled down"
        when "thread-dump"
          r = @application.threaddump
          if r.nil?
            msg = ""
          else
            msg = !r.errorIO.string.empty? ? r.errorIO.string.chomp : r.resultIO.string.chomp
          end
        when 'tidy'
          r = @application.tidy
          msg = "Application #{@application.name} called tidy"
        when 'reload'
          r = @application.reload_config
          msg = "Application #{@application.name} called reload"
        else
          return render_error(:unprocessable_entity, "Invalid application event '#{event}' specified",
                              126, "event")
        end
    rescue OpenShift::LockUnavailableException => e
      return render_error(:service_unavailable, "Application is currently busy performing another operation. Please try again in a minute.", e.code)
    rescue Exception => e
      return render_exception(e)
    end

    @application.with(consistency: :strong).reload
    app = get_rest_application(@application)
    render_success(:ok, "application", app, msg, r)
  end
  
  def set_log_tag
    event = params[:event]
    if event
      @log_tag = "#{event.sub('-', '_').upcase}_APPLICATION"
    else
      @log_tag = "UNKNOWN_EVENT_APPLICATION"
    end
  end
end
