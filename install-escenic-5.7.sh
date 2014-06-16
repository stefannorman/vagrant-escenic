#!/bin/bash
#
# Installs Escenic Engine ver 5.7 according to docs.
#
# Each step corresponds to a page in ece-install-guide. 
#
# @see http://docs.escenic.com/ece-install-guide/5.7/
# @author stefan.norman@bricco.se

DOWNLOAD_URI_TOMCAT="http://apache.mirrors.spacedump.net/tomcat/tomcat-7/v7.0.54/bin/apache-tomcat-7.0.54.tar.gz"
DOWNLOAD_URI_ENGINE="http://escenic:documentation@technet.escenic.com/downloads/release/57/engine-5.7.1.151922.zip"
DOWNLOAD_URI_ASSEMBLYTOOL="http://escenic:documentation@technet.escenic.com/downloads/release/56/assemblytool-2.0.5.zip"
DOWNLOAD_URI_MYSQL_DRIVER="http://dev.mysql.com/get/Downloads/Connector-J/mysql-connector-java-5.1.31.tar.gz"

DB_NAME="escenic"
DB_USER="escenic"
DB_PASSWORD="escenic"

# Install some script helpers
if [ ! -f /usr/bin/patch ]; then
    sudo apt-get -q -y install patch
fi

sudo apt-get -q update


# Start installing according install guide

# install_java_development_kit__jdk_.html
if [ ! -d /opt/java/jdk ]; then
    wget -nv --no-cookies --no-check-certificate --header "Cookie: gpw_e24=http%3A%2F%2Fwww.oracle.com%2F; oraclelicense=accept-securebackup-cookie" "http://download.oracle.com/otn-pub/java/jdk/7u60-b19/jdk-7u60-linux-x64.tar.gz"
    tar xf jdk-7u60-linux-x64.tar.gz
    sudo mkdir /opt/java/
    sudo mv jdk1.7.0_60 /opt/java/jdk
    sudo update-alternatives --install "/usr/bin/java" "java" "/opt/java/jdk/bin/java" 1
    sudo update-alternatives --set java /opt/java/jdk/bin/java
    rm -f jdk-7u60-linux-x64.tar.gz

    # Verify that Java is correctly installed
    java -version
fi

# install_ant.html
if [ ! -d /usr/share/ant/ ]; then
    sudo apt-get -q -y install ant

    # Verify that ant is correctly installed
    ant -version
fi

# install_various_utilities.html
if [ ! -f /usr/bin/unzip ]; then
    sudo apt-get -q -y install unzip
fi
if [ ! -f /usr/bin/telnet ]; then
    sudo apt-get -q -y install telnet
fi
# Skipped step openssh-server since Vagrant already took care of it

# create_escenic_user.html
if [ ! $(grep escenic /etc/passwd) ]; then
    # create user escenic with password escenic
    sudo useradd -p $(openssl passwd -1 escenic) -s /bin/bash -d /home/escenic escenic
    sudo mkdir /home/escenic
    sudo chown -R escenic:escenic /home/escenic

    sudo su escenic -c "echo 'export JAVA_HOME=/opt/java/jdk' >> ~/.bashrc"
    sudo su escenic -c "echo 'export PATH=\$JAVA_HOME/bin:\$PATH' >> ~/.bashrc"
fi

# create_shared_file_system.html
# Skipped this step since we are installing a single host

# download_content_engine.html
if [ ! -f /tmp/engine.zip ]; then
    wget -nv $DOWNLOAD_URI_ENGINE -O /tmp/engine.zip
fi
if [ ! -f /tmp/assemblytool.zip ]; then
    wget -nv $DOWNLOAD_URI_ASSEMBLYTOOL -O /tmp/assemblytool.zip
fi

# install_database.html
if [ ! -d /var/lib/mysql ];
then
    # Install MySQL
    sudo debconf-set-selections <<< 'mysql-server-5.5 mysql-server/root_password password rootpass'
    sudo debconf-set-selections <<< 'mysql-server-5.5 mysql-server/root_password_again password rootpass'
    sudo apt-get -q -y install mysql-server-5.5

    # Create ECE databases
    echo "CREATE USER '$DB_USER'@'localhost' IDENTIFIED BY '$DB_PASSWORD'" | mysql -uroot -prootpass
    echo "CREATE DATABASE $DB_NAME character set utf8 collate utf8_general_ci" | mysql -uroot -prootpass
    echo "GRANT ALL ON $DB_NAME.* TO '$DB_USER'@'localhost'" | mysql -uroot -prootpass
    echo "flush privileges" | mysql -uroot -prootpass

    # Change user to escenic and unpack the Content Engine package
    cd /tmp
    unzip -q engine.zip
    # Run the database scripts
    cd engine*/database/mysql/
    for el in tables.sql indexes.sql constants.sql constraints.sql; do
        mysql -u $DB_USER -p$DB_PASSWORD $DB_NAME < $el
    done;

    # Verify that MySQL is correctly installed
    mysqladmin -u root -prootpass status

fi

# install_application_server.html
if [ ! -d /opt/tomcat ]; then
    wget -nv $DOWNLOAD_URI_TOMCAT -O /tmp/apache-tomcat.tar.gz
    sudo tar -x -f /tmp/apache-tomcat.tar.gz -C /opt/
    TOMCAT_DIR=$(basename /opt/apache-tomcat-*)
    sudo ln -s /opt/$TOMCAT_DIR /opt/tomcat
    sudo chown -R escenic:escenic /opt/$TOMCAT_DIR

    # Add escenic/lib to catalina.properties
    cat << EOF > /tmp/diff.patch
--- /opt/tomcat/conf/catalina.properties   2014-05-19 19:35:04.000000000 +0000
+++ /tmp/catalina.properties    2014-06-14 08:39:12.832487700 +0000
@@ -46,7 +46,7 @@
 #     "foo/*.jar": Add all the JARs of the specified folder as class
 #                  repositories
 #     "foo/bar.jar": Add bar.jar as a class repository
-common.loader=\${catalina.base}/lib,\${catalina.base}/lib/*.jar,\${catalina.home}/lib,\${catalina.home}/lib/*.jar
+common.loader=\${catalina.base}/lib,\${catalina.base}/lib/*.jar,\${catalina.home}/lib,\${catalina.home}/lib/*.jar,\${catalina.home}/escenic/lib/*.jar

 #
 # List of comma-separated paths defining the contents of the "server"
EOF
    sudo patch /opt/tomcat/conf/catalina.properties < /tmp/diff.patch

    # Install MySQL driver
    wget -nv $DOWNLOAD_URI_MYSQL_DRIVER -O /tmp/mysql-connector.tar.gz
    tar -x -f /tmp/mysql-connector.tar.gz -C /tmp/
    sudo su escenic -c "cp /tmp/mysql-connector-java-*/mysql-connector-java-*-bin.jar /opt/tomcat/lib/"
    
    sudo su escenic -c "mkdir -p /opt/tomcat/escenic/lib/"

    # Set up database pooling and indexing
    cat << EOF > /tmp/diff.patch
--- /opt/tomcat/conf/context.xml    2014-05-19 19:35:04.000000000 +0000
+++ /tmp/context.xml    2014-06-14 09:29:35.570698327 +0000
@@ -18,6 +18,49 @@
 <!-- The contents of this file will be loaded for each web application -->
 <Context>

+    <Resource
+      name="jdbc/ECE_DS"
+      auth="Container"
+      type="javax.sql.DataSource"
+      username="$DB_USER"
+      password="$DB_PASSWORD"
+      driverClassName="com.mysql.jdbc.Driver"
+      maxActive="30"
+      maxIdle="10"
+      maxWait="5000"
+      url="jdbc:mysql://$DB_NAME/db-name?autoReconnect=true&amp;useUnicode=true&amp;characterEncoding=UTF-8"
+    />
+    <Environment
+      name="escenic/indexer-webservice"
+      value="http://indexer-web-service-host:8080/indexer-webservice/web-service-name/"
+      type="java.lang.String"
+      override="false"/>
+
+    <Environment
+      name="escenic/index-update-uri"
+      value="http://localhost:8080/solr/update/"
+      type="java.lang.String"
+      override="false"/>
+
+    <Environment
+      name="escenic/solr-base-uri"
+      value="http://localhost:8080/solr/"
+      type="java.lang.String"
+      override="false"/>
+
+    <Environment
+      name="escenic/head-tail-storage-file"
+      value="/var/lib/escenic/head-tail.index"
+      type="java.lang.String"
+      override="false"/>
+
+    <Environment
+      name="escenic/failing-documents-storage-file"
+      value="/var/lib/escenic/failures.index"
+      type="java.lang.String"
+      override="false"/>
+
+
     <!-- Default set of monitored resources -->
     <WatchedResource>WEB-INF/web.xml</WatchedResource>

@@ -32,4 +75,4 @@
     <Valve className="org.apache.catalina.valves.CometConnectionManagerValve" />
     -->

-</Context>
\ No newline at end of file
+</Context>
EOF
    sudo patch /opt/tomcat/conf/context.xml < /tmp/diff.patch

    # Add resource-link to web.xml
    cat << EOF > /tmp/diff.patch
--- /opt/tomcat/conf/web.xml    2014-05-19 19:35:04.000000000 +0000
+++ /tmp/web.xml    2014-06-14 09:48:19.632439023 +0000
@@ -21,6 +21,13 @@
                       http://java.sun.com/xml/ns/javaee/web-app_3_0.xsd"
   version="3.0">

+<resource-ref>
+  <description>Escenic link</description>
+  <res-ref-name>jdbc/ECE_DS</res-ref-name>
+  <res-type>javax.sql.DataSource</res-type>
+  <res-auth>Container</res-auth>
+</resource-ref>
+
   <!-- ======================== Introduction ============================== -->
   <!-- This document defines default values for *all* web applications      -->
   <!-- loaded into this instance of Tomcat.  As each application is         -->
EOF
    sudo patch /opt/tomcat/conf/web.xml < /tmp/diff.patch

    # Add URIEncoding to server.xml
    cat << EOF > /tmp/diff.patch
--- /opt/tomcat/conf/server.xml 2014-05-19 19:35:04.000000000 +0000
+++ /tmp/server.xml 2014-06-14 10:47:40.928447151 +0000
@@ -69,7 +69,8 @@
     -->
     <Connector port="8080" protocol="HTTP/1.1"
                connectionTimeout="20000"
-               redirectPort="8443" />
+               redirectPort="8443"
+               URIEncoding="UTF-8" />
     <!-- A "Connector" using the shared thread pool-->
     <!--
     <Connector executor="tomcatThreadPool"
EOF
    sudo patch /opt/tomcat/conf/server.xml < /tmp/diff.patch

fi

# create_configuration_folder.html
if [ ! -d /etc/escenic ]; then
    sudo mkdir -p /etc/escenic/engine
    sudo chown -R escenic:escenic /etc/escenic
fi

# unpack_content_engine_components.html
if [ ! -d /opt/escenic ]; then
    sudo mkdir /opt/escenic
    sudo unzip -q -d  /opt/escenic/ /tmp/engine.zip
    ENGINE_DIR=$(basename /opt/escenic/engine-*)
    sudo ln -s $ENGINE_DIR /opt/escenic/engine

    sudo mkdir /opt/escenic/assemblytool
    sudo unzip -q -d /opt/escenic/assemblytool /tmp/assemblytool.zip

    sudo chown -R escenic:escenic /opt/escenic
fi

# link_logging.html
if [ ! -f /opt/tomcat/lib/trace.properties ]; then
    sudo su escenic -c "mkdir /etc/escenic/engine/common"
    sudo su escenic -c "cat << EOF > /etc/escenic/engine/common/trace.properties
log4j.rootCategory=ERROR
log4j.category.com.escenic=ERROR, ECELOG
log4j.category.neo=ERROR, ECELOG
        
log4j.appender.ECELOG=org.apache.log4j.DailyRollingFileAppender
log4j.appender.ECELOG.File=/var/log/escenic/engine/ece-messages.log
log4j.appender.ECELOG.layout=org.apache.log4j.PatternLayout
log4j.appender.ECELOG.layout.ConversionPattern=%d %5p [%t] %x (%c) %m%n
EOF"
    sudo mkdir -p /var/log/escenic/engine 
    sudo chown -R escenic:escenic /var/log/escenic

    sudo su escenic -c "ln -s /etc/escenic/engine/common/trace.properties /opt/tomcat/lib/trace.properties"
fi

# copy_solr_configuration.html
if [ ! -d /var/lib/escenic/solr ]; then
    sudo mkdir -p /var/lib/escenic/solr
    sudo cp -r /opt/escenic/engine/solr/* /var/lib/escenic/solr/
    sudo chown -R escenic:escenic /var/lib/escenic
fi

# initialize_the_assembly_tool.html
if [ ! -f /opt/escenic/assemblytool/assemble.properties ]; then
    sudo su escenic -c "
        cd /opt/escenic/assemblytool
        ant initialize
    "
    cat << EOF > /tmp/diff.patch
--- /opt/escenic/assemblytool/assemble.properties   2014-06-14 12:42:05.756798860 +0000
+++ /tmp/assemble.properties    2014-06-14 12:43:15.910061349 +0000
@@ -11,7 +11,7 @@
 # The location of the Escenic Content Engine
 # Where have you unpacked engine-x.x-x.jar?
 #
-# engine.root = .
+engine.root = /opt/escenic/engine


 ###########################################################
EOF
    sudo patch /opt/escenic/assemblytool/assemble.properties < /tmp/diff.patch

fi

# initialize_edit_bootstrap_layer.html
if [ ! -d /opt/escenic/assemblytool/conf ]; then
    sudo su escenic -c "
        cd /opt/escenic/assemblytool
        ant -q ear
    "    
fi

# create_the_common_configuration_layer.html
if [ ! -f /etc/escenic/engine/common/Initial.properties ]; then
    sudo su escenic -c "
        cp -r /opt/escenic/engine/siteconfig/config-skeleton/* /etc/escenic/engine/common/
        cp -r /opt/escenic/engine/security/ /etc/escenic/engine/common/
    "
    cat << EOF > /tmp/diff.patch
--- /etc/escenic/engine/common/ServerConfig.properties  2014-06-14 12:55:29.017147631 +0000
+++ /tmp/ServerConfig.properties    2014-06-14 12:57:38.819310721 +0000
@@ -27,7 +27,7 @@
 # Default:
 #   No default product name.
 ############################################################################
-# databaseProductName=Oracle
+databaseProductName=MySQL


 ### ------------------------------------------------------------------- ###
@@ -65,7 +65,7 @@
 # Example:
 #   filePublicationRoot=/var/lib/escenic/engine/
 ############################################################################
-# filePublicationRoot=/var/lib/escenic/engine/
+filePublicationRoot=/var/lib/escenic/publications/
EOF
    sudo patch /etc/escenic/engine/common/ServerConfig.properties < /tmp/diff.patch

    cat << EOF > /tmp/diff.patch
--- /etc/escenic/engine/common/neo/io/managers/ContentManager.properties    2014-06-14 12:55:29.017147631 +0000
+++ /tmp/ContentManager.properties  2014-06-14 13:00:11.529884978 +0000
@@ -23,5 +23,5 @@
 # By default, the connector are the /neo/io/connector/SimpleDBPool connector
 ##############################################################################

-# dataConnector=/connector/DataConnector
+dataConnector=/connector/DataConnector
EOF
    sudo patch /etc/escenic/engine/common/neo/io/managers/ContentManager.properties < /tmp/diff.patch

fi

# create_host_configuration_layers.html
# Skipped this step since we are installing a single host

# install_the_ece_script.html
if [ ! -f /usr/bin/ece ]; then
    sudo cp /opt/escenic/engine/ece-scripts/usr/bin/ece /usr/bin
    sudo chmod +x /usr/bin/ece
    sudo su escenic -c "cp /opt/escenic/engine/ece-scripts/etc/escenic/ece.conf /etc/escenic/"
    cat << EOF > /tmp/diff.patch
--- /etc/escenic/ece.conf   2014-06-14 14:01:22.619042273 +0000
+++ /tmp/ece.conf   2014-06-14 14:24:55.256656779 +0000
@@ -26,7 +26,7 @@
 ########################################################################
 # Setting the java home, yes lowercase is correct ;-)
 ########################################################################
-java_home=/usr/lib/jvm/java-7-oracle
+java_home=/opt/java/jdk

 ########################################################################
 # Possible options are: tomcat, jboss, resin & oc4j
@@ -83,7 +83,7 @@
 jboss_home=/opt/jboss
 oc4j_home=/opt/oc4j
 resin_home=/opt/resin
-tomcat_home=/usr/share/tomcat6
+tomcat_home=/opt/tomcat

 # The tomcat_base may be different from tomcat_home. You set this
 # typically where you have several tomcat instances sharing the same
EOF
    sudo patch /etc/escenic/ece.conf < /tmp/diff.patch

    sudo mkdir -p /var/{crash,lib,log,run,cache,spool}/escenic
    sudo chown escenic:escenic /var/{crash,lib,log,run,cache,spool}/escenic -R
fi 

# assemble_and_deploy.html
sudo su escenic -c "ece assemble"
sudo su escenic -c "ece deploy"

exit 0