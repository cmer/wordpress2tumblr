require 'rubygems'
require 'mysql'            # gem install mysql
require 'active_record'    # gem install activerecord
require 'active_support'   # gem install activesupport
require 'pp'
require 'httparty'         # gem install httparty
require 'nokogiri'         # gem install nokogiri
require 'open-uri'


### TUMBLR SETTINGS ##########################################################
TUMBLR_EMAIL = "jbloe@example.org"
TUMBLR_PASSWORD = "swordfish"
TUMBLR_BLOG = "myblog"

### DISQUS COMMENT IMPORT ####################################################
# You can find your Disqus key here: http://disqus.com/api/get_my_key/
IMPORT_COMMENTS = true
DISQUS_KEY = "kjhKJhkJBi7iubBhjHJghjjhGjhGjhFvu6t86786t8tHGHJGhjgjghjJHfrsDFdfd"
DISQUS_FORUM_SHORTNAME = "cmercier"

### IMAGES ###################################################################
# Tumblr cannot host images embedded in posts. You will need to host them
# yourself. If you want to move them to a new host, enter its location here.
# This script will update the IMG tags with the new URL. You will need to
# upload the pictures yourself. If you do not want to move the images, set
# move_images to false.
MOVE_IMAGES = true
MOVE_IMAGES_TO = "http://images.example.org"
LOCAL_IMAGE_PATH = "/tmp/blog-images/"

### WORDPRESS ################################################################
# These are the settings to connect to your Wordpress database.
db_config = { :adapter => 'mysql',
              :database => 'wordpress',
              :username => 'root',
              :password => '' }




##############################################################################
### DO NOT EDIT PAST THIS ####################################################
##############################################################################

GENERATOR = "Carl Mercier's WP2Tumblr Importer"

class Post < ActiveRecord::Base
  set_table_name :wp_posts
  set_primary_key 'ID'
  has_many :comments, :foreign_key => "comment_post_ID"
  default_scope :conditions => "post_type='post' AND post_status='publish'"
end

class Comment < ActiveRecord::Base
  set_table_name :wp_comments
  set_primary_key 'comment_ID'
  belongs_to :post, :foreign_key => "comment_post_ID"
  default_scope :conditions => { :comment_approved => 1}
end

class Tumblr
  include HTTParty
  
  def initialize(email, password, blog)
    @email, @password, @blog = email, password, blog
  end


  def write(params)
    params.merge!( { :email     => @email, 
                     :password  => @password, 
                     :group     => "#{@blog}.tumblr.com",
                     :generator => GENERATOR } )

    post = self.class.post('http://www.tumblr.com/api/write', :body => params)
    if post.response.code.to_s == "201"
      post_id = post.response.body
      "http://#{@blog}.tumblr.com/post/#{post_id}/#{params[:slug]}"
    else
      post.response
    end
  end
end

class Disqus
  include HTTParty
  base_uri 'disqus.com/api'
  API_VERSION = "1.1"


  def initialize(key, forum_shortname)
    puts "Initializing Disqus..."
    @key, @forum_shortname = key, forum_shortname
    forum_list = self.class.get('/get_forum_list', :query => { :user_api_key => @key, 
                                                               :api_version => API_VERSION }).parsed_response["message"]
    forum_list.each do |forum|
      if forum["shortname"] == forum_shortname
        @forum_id = forum["id"]
        puts "  Found forum id for #{forum_shortname}: #{@forum_id}"
        break
      end
    end
    if @forum_id.nil?
      puts "  --> Couldn't find Disqus forum for shortname #{forum_shortname}. Can't continue."
      exit 1
    end
    
    @forum_api_key = self.class.get('/get_forum_api_key', :query => { :user_api_key => @key, 
                                                                      :api_version => API_VERSION, 
                                                                      :forum_id => @forum_id}).parsed_response["message"]
    puts "  Forum API key is #{@forum_api_key}."
  end


  # Get the thread id or create a new thread if needed
  def get_thread_id(url, title, slug)
    # Is there already a thread for this url?
    
    thread = self.class.get('/get_thread_by_url/', :query => { :url => url, 
                                                               :forum_api_key => @forum_api_key, 
                                                               :api_version => API_VERSION }).parsed_response

    if thread["message"].nil?
      # We have to create a new thread and then set the URL and slug. Disqus won't let me do this in
      # one go AFAIK.
      identifier = url.match(/\/post\/(\d+)/)[1]
      new_thread = self.class.post('/thread_by_identifier/', :body => { :identifier => identifier,
                                                                        :url => url,
                                                                        :title => title,
                                                                        :forum_api_key => @forum_api_key,
                                                                        :create_on_fail => 1, 
                                                                        :api_version => API_VERSION }).parsed_response
                                                                        
      thread_id = new_thread["message"]["thread"]["id"]
      updated_thread = self.class.post('/update_thread/', :body => { :thread_id => thread_id, 
                                                                     :forum_api_key => @forum_api_key,
                                                                     :url => url,
                                                                     :title => title,
                                                                     :slug => slug,
                                                                     :api_version => API_VERSION }).parsed_response                                                                      
    else
      thread_id = thread["message"]["id"]
    end

    thread_id
  end


  # Add the comment to Disqus. Doesn't support nested comments.
  def create_comment(thread_id, author_name, author_email, author_url, message, ip_address, created_at, parent_post = nil)
    self.class.post('/create_post/', :body => { :thread_id => thread_id,
                                                :author_name => author_name,
                                                :author_email => author_email,
                                                :author_url => author_url,
                                                :message => message,
                                                :forum_api_key => @forum_api_key,
                                                :state => 'approved',
                                                :ip_address => ip_address,
                                                :created_at => created_at }).parsed_response
  end
end


# Very simple HTML character replacement.
def decode_html(html)
  replacements = [ ["&#8230;", "..."],
                   ["&#8217;", "'"],
                   ["&#8212", "--"],
                   ["&#8211", "--"] ]

  replacements.each do |pair|
    html.gsub!(pair[0], pair[1])
  end
  html
end


# Change IMG SRC to refect new image server and download image files locally
# for manual upload.
def move_images(post_content)
  uri = MOVE_IMAGES_TO.strip
  uri += "/" unless uri.match(/\/$/)
  
  img_urls = []
  doc = Nokogiri::HTML(post_content)
  doc.css('img').each do |img|
    img_urls << img.attributes["src"].to_s
  end
  
  puts "  Downloading #{img_urls.size} image(s)." if img_urls.size > 0
  
  img_urls.each do |url|
    local_img_path = download_file(url, LOCAL_IMAGE_PATH)
    post_content = post_content.gsub(url, uri + local_img_path.split("/").last) if local_img_path
  end
  
  post_content
end


# Download file to local path
def download_file(url, local_path)
  local_path += "/" unless local_path.match(/\/$/)
  `mkdir -p #{local_path}`
  
  uri = URI.parse(url)
  filename = uri.path.split("/").last
  
  # If file already exists locally, give it a new randomized name to avoid clashes
  filename = Digest::MD5.hexdigest(Time.now.to_s)  + "-#{filename}" if File.exists?(local_path + filename)

  writeOut = open(local_path + filename, 'wb')
  writeOut.write(open(uri).read)
  writeOut.close

  # return the download file local path
  local_path + filename
rescue OpenURI::HTTPError => ex
  puts "  HTTPError while downloading file: #{ex.message}"
  nil
end


def run
  i=0

  disqus = Disqus.new(DISQUS_KEY, DISQUS_FORUM_SHORTNAME) if IMPORT_COMMENTS
  puts "\n\n"
  
  Post.all.each do |p|
    i+=1

    post_title = decode_html(p.post_title)
    post_content = decode_html(p.post_content)
    puts "Importing '#{post_title}'. #{p.comments.size} comments"
    
    # download images locally and change img src
    post_content = move_images(post_content) if MOVE_IMAGES

    tumblr_post_url = Tumblr.new(TUMBLR_EMAIL, TUMBLR_PASSWORD, TUMBLR_BLOG).write(
      :type   => "regular", 
      :title  => post_title,
      :body   => post_content,
      :slug   => p.post_name,
      :date   => p.post_date.to_s
    )
  
    if p.comments.size > 0 && IMPORT_COMMENTS
      puts "  Transfering #{p.comments.size} comments to Disqus"
      thread_id = disqus.get_thread_id(tumblr_post_url, post_title, p.post_name)
      puts "  Disqus thread id: #{thread_id}"
      
      p.comments.each do |c|
        disqus.create_comment(thread_id,
                              c.comment_author,
                              c.comment_author_email,
                              c.comment_author_url,
                              c.comment_content,
                              c["comment_author_IP"],
                              c.comment_date_gmt.strftime("%Y-%m-%dT%H:%M"))
      end
    end

    puts "\n-------------------------------------------------------------\n\n"
  end

  puts "\n\n\n\n\nDone! Imported #{i} posts."
  puts "Your images have been downloaded to #{LOCAL_IMAGE_PATH}. Make sure to upload them to #{MOVE_IMAGES_TO}." if MOVE_IMAGES
end

ActiveRecord::Base.establish_connection(db_config)
run
