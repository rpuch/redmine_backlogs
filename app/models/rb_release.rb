require 'date'

class ReleaseBurndown
  def initialize(release)
#    @days = release.days
    @release_id = release.id
    @project = release.project

    # Select closed sprints within release period
    sprints = release.closed_sprints
    return if sprints.nil?

    baseline = [0] * sprints.size

    series = Backlogs::MergedArray.new
    series.merge(:backlog_points => baseline.dup)
    series.merge(:added_points => baseline.dup)
    series.merge(:closed_points => baseline.dup)

#TODO Caching
#TODO Maybe utilize/extend sprint burndown data?
#TODO Stories continued over several sprints (by duplicating) should not show up as added
#TODO Likewise stories split from inital epics should not show up as added

    # Go through each story of each sprint
    sprints.each{ |sprint|
      sprint.stories.each{ |story|
#BUG Stories closed after sprint end date will show up as closed in the next sprint...
        series.add(story.release(sprints))
      }
    }
    # Go through each open story in the backlog
    release.stories.each{ |story|
      series.add(story.release(sprints))
    }

    # Series collected, now format data for jqplot
    # Slightly hacky formatting to get the correct view. Might change when this jqplot issue is 
    # sorted out:
    # See https://bitbucket.org/cleonello/jqplot/issue/181/nagative-values-in-stacked-bar-chart
#TODO Maybe move jqplot format stuff to releaseburndown view?
    @data = {}
    @data[:added_points] = series.collect{ |s| -1 * s.added_points }
    @data[:added_points_pos] = series.collect{ |s| s.backlog_points >= 0 ? s.added_points : s.added_points + s.backlog_points }
    @data[:backlog_points] = series.collect{ |s| s.backlog_points >= 0 ? s.backlog_points : 0 }
    @data[:closed_points] = series.series(:closed_points)


    # Forecast (probably just as good as the weather forecast...)
#TODO Move forecast to RbRelease?
    @data[:trend_closed] = Array.new
    @data[:trend_added] = Array.new
    avg_count = 3
    if sprints.size >= avg_count
      avg_added = (@data[:added_points][-1] - @data[:added_points][-avg_count]) / avg_count
      avg_closed = @data[:closed_points][-avg_count..-1].inject(0){|sum,p| sum += p} / avg_count
      current_backlog = @data[:added_points][-1] + @data[:added_points_pos][-1] + @data[:backlog_points][-1]
      current_added = @data[:added_points][-1]
      current_sprints = @data[:closed_points].size

      # Add beginning and end dataset [sprint,points] for trendlines
      @data[:trend_closed] << [current_sprints, current_backlog]
      @data[:trend_closed] << [current_sprints + 10, current_backlog - avg_closed * 10]
      @data[:trend_added] << [current_sprints, current_added]
      @data[:trend_added] << [current_sprints + 10, current_added + avg_added * 10]

    end

#TODO Estimate sprints left
    sprints_left = [0] * 10

    # Extend other series with empty datapoints up to the estimated number of sprints
    # to format plot correctly
    @data[:added_points].concat sprints_left.dup
    @data[:added_points_pos].concat sprints_left.dup
    @data[:backlog_points].concat sprints_left.dup
    @data[:closed_points].concat sprints_left.dup
  end

  def [](i)
    i = i.intern if i.is_a?(String)
    raise "No burn#{@direction} data series '#{i}', available: #{@data.keys.inspect}" unless @data[i]
    return @data[i]
  end

  def series(select = :active)
    return @data.keys.collect{ |k| k.to_s }
#    return @available_series.values.select{|s| (select == :all) }.sort{|x,y| "#{x.name}" <=> "#{y.name}"}
  end

  attr_reader :days
  attr_reader :release_id
  attr_reader :max

  attr_reader :remaining_story_points
  attr_reader :ideal
end

class RbRelease < ActiveRecord::Base
  set_table_name 'releases'

  unloadable

  belongs_to :project
  has_many :release_burndown_days, :dependent => :delete_all, :foreign_key => :release_id

  validates_presence_of :project_id, :name, :release_start_date, :release_end_date, :initial_story_points
  validates_length_of :name, :maximum => 64
  validate :dates_valid?

  def dates_valid?
    errors.add_to_base(l(:error_release_end_after_start)) if self.release_start_date >= self.release_end_date if self.release_start_date and self.release_end_date
  end

  # Return sprints closed within this release
  def closed_sprints
    sprints = RbSprint.closed_sprints(self.project).reject!{ |s|
      s.effective_date == nil ||
      s.sprint_start_date < self.release_start_date ||
      s.effective_date > self.release_end_date
    }
    return sprints
  end

  def stories
    return RbStory.stories_open(@project)
  end

  def burndown_days
    self.release_burndown_days.sort { |a,b| a.day <=> b.day }
  end

  def days(cutoff = nil)
    # assumes mon-fri are working days, sat-sun are not. this
    # assumption is not globally right, we need to make this configurable.
    cutoff = self.release_end_date if cutoff.nil?
    workdays(self.release_start_date, cutoff)
  end

  def has_burndown?
    return !!(self.release_start_date and self.release_end_date and self.initial_story_points && !self.closed_sprints.nil?)
  end

  def burndown
    return nil if not self.has_burndown?
    @cached_burndown ||= ReleaseBurndown.new(self)
    return @cached_burndown
  end

  def today
    ReleaseBurndownDay.find(:first, :conditions => { :release_id => self, :day => Date.today })
  end

end
