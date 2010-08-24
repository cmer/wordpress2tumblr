Carl Mercier's Wordpress-to-Tumblr Importer
===========================================

This script will import your Wordpress posts to Tumblr. Optionally, it can also import comments into Disqus and move inline images to a different server since Tumblr doesn't host inline images.

HOW TO USE:
-----------

1.  Install Ruby 1.8.7 and Rubygems. The script likely works on Ruby 1.9.2 but it hasn't been tested.
2.  Install the required gems. See the list at the top of wp2tumblr.rb.
3.  Edit wp2tumblr.rb with your settings.
4.  Run the script: ruby ./wp2tumblr.rb
5.  Grab a cold one and enjoy all the hard work being done for you.
6.  If you want to move your images, make sure you upload them to your new server. This is NOT automated. The images will be placed in a local directory.

