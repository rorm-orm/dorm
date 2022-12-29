mysqladmin -h 127.0.0.1 -u username -ppassword -f drop db || true
mysqladmin -h 127.0.0.1 -u username -ppassword create db || true
