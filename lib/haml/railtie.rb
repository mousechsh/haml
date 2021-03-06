if defined?(ActiveSupport)
  # check for a compatible Rails version when Haml is loaded
  if (activesupport_spec = Gem.loaded_specs['activesupport'])
    if activesupport_spec.version.to_s < '3.2'
      raise Exception.new("\n\n** Haml now requires Rails 3.2 and later. Use Haml version 4.0.4\n\n")
    end
  end

  require 'haml/template/options'
  ActiveSupport.on_load(:action_view) do
    require "haml/template"

    if defined? Erubi
      require "haml/helpers/safe_erubi_template"
      Haml::Filters::Erb.template_class = Haml::SafeErubiTemplate
    else
      require "haml/helpers/safe_erubis_template"
      Haml::Filters::Erb.template_class = Haml::SafeErubisTemplate
    end
  end
end

module Haml
  class Railtie < ::Rails::Railtie
    initializer :haml do |app|
      require "haml/template"
      if defined?(::Sass::Rails::SassTemplate) && app.config.assets.enabled
        require "haml/sass_rails_filter"
      end
      Haml::Options.buffer_defaults.keys.each do |key|
        if Haml::Template.options.key?(key)
          Haml::Options.buffer_defaults[key] = Haml::Template.options[key]
        end
      end
    end
  end
end
