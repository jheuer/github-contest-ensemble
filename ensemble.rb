# Copyright (c) 2009 Jeff Heuer
# 
# Permission is hereby granted, free of charge, to any person
# obtaining a copy of this software and associated documentation
# files (the "Software"), to deal in the Software without
# restriction, including without limitation the rights to use,
# copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the
# Software is furnished to do so, subject to the following
# conditions:
# 
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES
# OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
# HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
# WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR
# OTHER DEALINGS IN THE SOFTWARE.
# 
# Except as contained in this notice, the name(s) of the above 
# copyright holders shall not be used in advertising or otherwise 
# to promote the sale, use or other dealings in this Software 
# without prior written authorization.

require 'rubygems'
require 'hpricot'
require 'open-uri'
require 'resultset'

class Ensemble
  
  def initialize(options = {})
    defaults = {
      :ensemble_size => 10,
      :similarity_measure => :jaccard,
      :first_member => :best,
      :diversity_weight => :score,
      :blending_weight => :rank_within_resultset,
      :repo_recommendations_per_user => 10,
      :results_file => 'results',
      :save_intermediate_results => true
    }
    options = defaults.merge(options)
    # TODO: allow specification of starting member
    raise "Unknown first member: #{options[:first_member]}" unless [:best, :random].include? options[:first_member]
    raise "Unknown similarity measure: #{options[:similarity_measure]}" unless [:jaccard, :inverse_popularity_weighted_jaccard, :dice].include? options[:similarity_measure]
    raise "Unknown diversity weight: #{options[:diversity_weight]}" unless [:score, :sqrt_score, :log_score, :rank].include? options[:diversity_weight]
    raise "Unknown blending weight: #{options[:blending_weight]}" \
      unless [:equal, :rank_within_ensemble, :rank_within_resultset, :score, :sqrt_score, :log_score].include? options[:blending_weight]

    @ensemble_size                          = options[:ensemble_size].freeze
    @repo_recommendations_per_user          = options[:repo_recommendations_per_user].freeze
    @create_ensemble_with_replacement       = options[:create_ensemble_with_replacement].freeze
    @similarity_measure                     = options[:similarity_measure].freeze
    @first_member                           = options[:first_member].freeze
    @diversity_weight                       = options[:diversity_weight].freeze
    @blending_weight                        = options[:blending_weight].freeze
    @results_file                           = options[:results_file].freeze
    @save_intermediate_results              = options[:save_intermediate_results].freeze

    @resultsets = []
    @ensemble_members = []
  end
  
  def run
    raise "Not enough resultsets to form ensemble (have #{@resultsets.size}, need #{@ensemble_size})" unless @resultsets.size > @ensemble_size

    puts
    calculate_repo_popularities if @similarity_measure == :inverse_popularity_weighted_jaccard || @repo_specific_blending_weight == :repo_popularity

    @resultsets.sort{ |x,y| y.score <=> x.score }
    puts "Forming ensemble of #{@ensemble_size} from #{@resultsets.size} resultsets\n"
    build_ensemble
    puts "\nFinal ensemble members:"
    @ensemble_members.each { |rs| puts "  #{rs.to_s_with_commit}" }
    puts "\nBlending ensemble results..."
    user_recommendations = blend_results(@ensemble_members)
    results_filename = @results_file + '.txt'
    puts "Saving results to #{results_filename}..."
    save_results(user_recommendations, results_filename)
    puts "Done!"
  end
  
  def calculate_repo_popularities
    puts "Calculating repo popularities within resultsets..."
    @repo_popularities = {}
    total_observations = 0
    @resultsets.each do |rs|
      print '.'
      rs.results.each do |user, repo|
        @repo_popularities[repo] ||= 0
        @repo_popularities[repo] += 1
        total_observations += 1
      end
    end
    @repo_popularities.each_pair { |repo, count| @repo_popularities[repo] = count / total_observations.to_f }
    puts "\nTop 10 repos"
    @repo_popularities.sort{ |x,y| y[1] <=> x[1] }[0,10].each_with_index{ |r,i| puts "  ##{i+1}:#{r[0].to_s}" }
  end
  
  # Populates @resultsets with an array of ResultSet objects by parsing the GitHub contest leaderboard
  # RestultSets contain metadata on user, repo, commit_sha, and score, but not the actual results.txt
  def load_resultsets_from_leaderboard(options = {})
    defaults = {
      :load_from_cache => false,
      :ignore_repos => [],
      :top_n_from_leaderboard => nil,
      :min_score => 250, 
      :top_n_commits_per_repo => 1,
      :top_n_commits_total => nil,
      :sleep_seconds_between_github_requests => 15
    }
    options = defaults.merge(options)
    @ignore_repos                           = options[:ignore_repos].freeze
    @top_n_from_leaderboard                 = options[:top_n_from_leaderboard].freeze
    @min_score                              = options[:min_score].freeze
    @top_n_commits_per_repo                 = options[:top_n_commits_per_repo].freeze
    @top_n_commits_total                    = options[:top_n_commits_total].freeze
    @sleep_seconds_between_github_requests  = options[:sleep_seconds_between_github_requests].freeze
    ResultSet.sleep_seconds_between_github_requests = @sleep_seconds_between_github_requests
    
    all_resultsets = []
    if options[:load_from_cache]
      all_resultsets = ResultSet.load_from_cache
    else
      doc = Hpricot(open('http://contest.github.com/leaderboard'))
      (doc/'table.leaderboard tr:gt(0)').each_with_index do |tr, i|
        break if @top_n_from_leaderboard && i >= (@top_n_from_leaderboard + @ignore_repos.size)
        repo_link = tr.at('td:eq(0) a')
        user, repo = repo_link.inner_text.split('/')
        high_score = tr.at('td:eq(1)').inner_text.to_i
        print "##{i+1}: #{user}/#{repo}, high score: #{high_score}"
        if @ignore_repos.include?(user + '/' + repo) || (@min_score && high_score < @min_score)
          print " (Skipping)\n"
          next
        end
        print "\n"
        
        all_resultsets += ResultSet.get_for_contest_repo(user, repo)
      end
    end
    
    # filter results
    # TODO: @top_n_from_leaderboard
    all_resultsets.reject!{ |rs| rs.score <= @min_score } unless @min_score.nil?
    unique_repos = all_resultsets.collect{ |c| [c.user, c.repo] }.uniq
    unique_repos.each do |user, repo|
      repo_resultsets = all_resultsets.select{ |c| c.user == user && c.repo == repo }
      repo_resultsets.sort!{ |x,y| y.score <=> x.score }
      repo_resultsets = repo_resultsets[0,@top_n_commits_per_repo] unless @top_n_commits_per_repo.nil?
      @resultsets = @resultsets + repo_resultsets
    end
    @resultsets.sort!{ |x,y| y.score <=> x.score }
    @resultsets = @resultsets.reject{ |c| @ignore_repos.include?(c.user + '/' + c.repo) }
    @resultsets = @resultsets[0,@top_n_commits_total] unless @top_n_commits_total.nil?
    
    # cache
    @resultsets.each do |rs|
      begin
        rs.raw_results
      rescue
        @resultsets.delete(rs)
      end
    end
  end

  def build_ensemble
    @full_resultset = @resultsets.dup
    similarity_vector = initialize_ensemble
    puts
    last_user_recommendations = {}
    (1..@ensemble_size-1).each do |iteration|
      best_score = best_i = 0
      similarity_vector.each_with_index do |col_similarity, col_i|
        next if @resultsets[col_i] == @ensemble_members.last # if allowing duplicates, prevent loops
        score = case @diversity_weight
        when :rank
          rank = (@resultsets.size - col_i + 1)
          rank * (1-col_similarity)
        when :score
          @resultsets[col_i].score * (1-col_similarity)
        when :sqrt_score
          Math.sqrt(@resultsets[col_i].score) * (1-col_similarity)
        when :log_score
          Math.log(@resultsets[col_i].score) * (1-col_similarity)
        end
        
        if score > best_score
          best_score, best_i = score, col_i
        end
      end
      puts "\n  Added #{@resultsets[best_i].to_s}"
      puts"    Similarity to existing ensemble: #{similarity_vector[best_i]}"
      @ensemble_members << @resultsets[best_i]
      unless @create_ensemble_with_replacement
        # disregard all results from this user/repo going forward
        @resultsets.reject!{ |c| c.user == @resultsets[best_i].user && c.repo == @resultsets[best_i].repo }
      end
      
      user_recommendations = blend_results(@ensemble_members)
      save_results(user_recommendations, "#{@results_file}_#{iteration+1}.txt") if @save_intermediate_results

      unless iteration > 1
        cross_similarity = similarity(hash_to_array(user_recommendations), hash_to_array(last_user_recommendations))
        puts "    Ensemble cross-similarity to last iteration: #{cross_similarity}"
      end
      last_user_recommendations = user_recommendations
      
      # recalculate ensemble_correlations
      unless iteration == @ensemble_size-1
        print "    Looking for member #{iteration+2}"
        similarity_vector = pairwise_similarities(hash_to_array(user_recommendations))
        puts
      end
    end # find 1..n ensemble members    
    @ensemble_members
  end
  
  def initialize_ensemble
    case @first_member
    when :best
      @ensemble_members << @resultsets[0]
    when :random
      @ensemble_members << @resultsets[rand(@resultsets.size)]
    end
    puts "  Seeding ensemble with #{@ensemble_members.first.to_s}"

    unless @create_ensemble_with_replacement
      @resultsets = @resultsets.reject{ |c| c.user == @ensemble_members.first.user && c.repo == @ensemble_members.first.repo } 
    end
    print "    Looking for member 2"
    pairwise_similarities(@ensemble_members.first.results)
  end
  
  def pairwise_similarities(base_commit_results)
    @resultsets.collect do |rs|
      print '.'
      similarity(base_commit_results, rs.results)
    end    
  end
  
  # Calculate the similarity between a pair of two-dimensional arrays
  # e.g. [[user_1, repo_1], [user_1, repo_3], ...]
  def similarity(repo_recs1, repo_recs2)
    case @similarity_measure
    when :jaccard
      (repo_recs1 & repo_recs2).size / (repo_recs1 | repo_recs2).size.to_f
    when :inverse_popularity_weighted_jaccard
      intersection = repo_recs1 & repo_recs2
      numerator = 0
      intersection.each { |user, repo| numerator += (1 - @repo_popularities[repo]) }
      numerator / (repo_recs1 | repo_recs2).size.to_f
    when :dice
      (2 * (repo_recs1 & repo_recs2).size) / (repo_recs1.size + repo_recs2.size).to_f
    end
  end
  
  # TODO: move to ResultSet?
  def hash_to_array(h)
    a = []
    h.each_pair do |user, repo_scores|
      repo_scores.each do |repo, score|
        a << [user, repo]
      end
    end
    a
  end
  
  # return { :user1 => [ [:repo1, 5], [:repo2, 3], ... ], ... }
  def blend_results(ensemble_members)
    user_recommendations = {}
    ensemble_members.each do |rs|
      resultset_vote_weight = case @blending_weight
      when :equal
        1
      when :rank_within_ensemble
        ensemble_members.size - (ensemble_members.index(rs) + 1)
      when :rank_within_resultset
        @full_resultset.size - (@full_resultset.index(rs) + 1)
      when :score
        rs.score.to_i
      when :sqrt_score
        Math.sqrt(rs.score.to_i)
      when :log_score
        Math.log(rs.score.to_i)
      end

      rs.results.each do |user, repo|
        user_recommendations[user] = {} unless user_recommendations.has_key?(user)
        if user_recommendations[user][repo].nil?
          user_recommendations[user][repo] = resultset_vote_weight
        else
          user_recommendations[user][repo] += resultset_vote_weight
        end
      end
    end # each contest repo
    
    # TODO: break ties randomly?
    user_recommendations.each_pair do |user, repos|
      user_recommendations[user] = repos.sort{|x,y| y[1] <=> x[1]}[0,@repo_recommendations_per_user]
    end
    user_recommendations
  end
  
  def save_results(user_recommendations, filename)
    File.open(filename, 'w') do |f|
      File.open('data/test.txt', 'r').each_line do |line|
        user = line.chomp
        top_recs = user_recommendations[user]
        top_recs.sort!{|x,y| x[0].to_i <=> y[0].to_i} # now sort by repo id
        output_line = "#{user}:#{top_recs.collect{ |r| r[0]}.join(',') }"
#        puts output_line
        f.write(output_line + "\n")
      end # close test file
    end # close result file
  end
end

