# frozen_string_literal: true

module AgentHarness
  # Filesystem-backed registry for reusable agent skills.
  module Skills
    GLOBAL_SKILLS_DIR = File.join(".agent-harness", "skills")
    PROJECT_SKILLS_DIR = File.join(".agent-harness", "skills")
    SHARED_SKILLS_DIR = File.join(".agents", "skills")

    class << self
      def discover(cwd: Dir.pwd, home: Dir.home, refresh: false)
        cache_key = [File.expand_path(cwd), File.expand_path(home)]
        @discovered ||= {}
        @registry ||= {}
        @discovered.delete(cache_key) if refresh
        @discovered[cache_key] ||= discover_registry(cwd: cwd, home: home)

        combined_registry(cache_key).values
      end

      def find(name, cwd: Dir.pwd, home: Dir.home)
        cache_key = [File.expand_path(cwd), File.expand_path(home)]
        discover(cwd: cwd, home: home)

        combined_registry(cache_key).fetch(name.to_sym) do
          raise ConfigurationError, "Unknown skill: #{name}"
        end
      end

      def register(name, attributes)
        @registry ||= {}
        skill = case attributes
        when Skill
          attributes
        when Hash
          Skill.from_hash(attributes.merge(name: name))
        else
          raise ConfigurationError, "Skill registration must be a Skill or Hash"
        end

        @registry[skill.name] = skill
      end

      def resolve(reference, cwd: Dir.pwd, home: Dir.home)
        case reference
        when nil
          nil
        when Skill
          reference
        when Hash
          Skill.from_hash(reference)
        else
          find(reference, cwd: cwd, home: home)
        end
      end

      def resolve_all(references, cwd: Dir.pwd, home: Dir.home)
        Array(references).filter_map { |reference| resolve(reference, cwd: cwd, home: home) }
      end

      def reset!
        @registry = {}
        @discovered = {}
      end

      private

      def combined_registry(cache_key)
        discovered_registry = @discovered.fetch(cache_key)
        discovered_registry.merge(@registry || {})
      end

      def discover_registry(cwd:, home:)
        skill_paths_for(cwd: cwd, home: home).each_with_object({}) do |path, memo|
          skill = Skill.load_file(path)
          memo[skill.name] = skill
        end
      end

      def skill_paths_for(cwd:, home:)
        [
          File.join(File.expand_path(home), GLOBAL_SKILLS_DIR),
          File.join(File.expand_path(cwd), SHARED_SKILLS_DIR),
          File.join(File.expand_path(cwd), PROJECT_SKILLS_DIR)
        ].flat_map do |directory|
          next [] unless Dir.exist?(directory)

          direct_skill = File.join(directory, "SKILL.md")
          nested_skills = Dir.glob(File.join(directory, "*", "SKILL.md")).sort
          ([direct_skill] + nested_skills).select { |path| File.file?(path) }
        end
      end
    end
  end
end
