#!/bin/bash
WOKR_DIR="$HOME/jupyter_data"

function installKernelGateway {
  yes | pip install "ipython<6.0" --user --upgrade
  yes | pip install jupyter_kernel_gateway --user
}

function setJupyterDataDir {
  if ! [ -d $WOKR_DIR ]
  then mkdir $WOKR_DIR
  else echo "$WOKR_DIR directory exists"
  fi

  if grep --quiet JUPYTER_DATA_DIR ~/.bashrc
  then echo "JUPYTER_DATA_DIR already defined"
  else echo '' >> ~/.bashrc
    echo "export JUPYTER_DATA_DIR=$WOKR_DIR" >> ~/.bashrc
  fi
  source ~/.bashrc
}

function hidden_input {
  unset input
  while IFS= read -p "$prompt" -r -s -n 1 char
  do
      if [[ $char == $'\0' ]]
      then
          break
      fi
      prompt='*'
      input+="$char"
  done
  echo "$input"
}

function setPortAndToken {
  if grep --quiet KG_AUTH_TOKEN ~/.bashrc
  then echo 'KG_AUTH_TOKEN already defined'
  else
    prompt="Enter the token that will be used for kernel gateway authorization, followed by [ENTER]:"
    TOKEN=$(hidden_input)
    echo
    if [ -z "${TOKEN}" ]
    then
      echo "No token provided. Please provide a token."
      exit 1
    fi
    prompt="Enter the token again, followed by [ENTER]:"
    TOKEN_CHECK=$(hidden_input)
    echo
    if [ "${TOKEN}" != "${TOKEN_CHECK}" ]
    then
      echo "Personal access token and confirmation did not match. Script will exit. Please run it again."
      exit 1
    fi
    echo "export KG_AUTH_TOKEN=\"${TOKEN}\"" >> ~/.bashrc
  fi
  if [ -z $PORT ]
  then
    echo "Enter Kernel Gateway port, followed by [ENTER]:"
    read PORT
  fi
  if [ -z $PORT ]
  then
    PORT=80
  fi
  source ~/.bashrc
}

function createKernelsFolder {
  if ! [ -d $WOKR_DIR/kernels ]
  then mkdir $WOKR_DIR/kernels
  else echo "$WOKR_DIR/kernels directory already exists"
  fi
}

function setupPySparkKernel {
  if ! [ -d $WOKR_DIR/kernels/pyspark ]
  then mkdir $WOKR_DIR/kernels/pyspark
  else echo "$WOKR_DIR/kernels/pyspark directory already exists"
  fi
  createKernelJSON
  createKernelWrapperScript
  echo "PySpark kernel configured"
}

function createKernelJSON {
  if [ ! -f $WOKR_DIR/kernels/pyspark/kernel.json ]
  then
    touch $WOKR_DIR/kernels/pyspark/kernel.json
  fi
  echo "
  {
   \"display_name\": \"Python 2 with Spark\",
   \"language\": \"python\",
   \"argv\": [
    \"/home/$USER/jupyter_data/pyspark_wrapper\",
    \"{connection_file}\"
   ]
  }
  " > $WOKR_DIR/kernels/pyspark/kernel.json
}

function createKernelWrapperScript {
  if [ ! -f $WOKR_DIR/pyspark_wrapper ]
  then
    touch $WOKR_DIR/pyspark_wrapper
  fi
  echo '#!/usr/bin/env bash

  connectionfile="$1"
  export PYSPARK_DRIVER_PYTHON_OPTS="-m ipykernel -f \"${connectionfile}\""
  /usr/bin/pyspark
  ' > $WOKR_DIR/pyspark_wrapper
  chmod +x $WOKR_DIR/pyspark_wrapper
}

function startKernelGateway {
  if [ -z $PORT ]
  then
    echo "Enter Kernel Gateway port, followed by [ENTER]:"
    read PORT
  fi
  if [ -z $PORT ]
  then
    PORT=80
  fi
  cd $HOME
  nohup ~/.local/bin/jupyter-kernelgateway --KernelGatewayApp.ip=0.0.0.0 --KernelGatewayApp.port=$PORT '--KernelSpecManager.whitelist=["pyspark"]'> ~/kg_log 2>&1 &
  sleep 3
  testKernelGateway $PORT
  AWS_HOST=$(curl -s http://169.254.169.254/latest/meta-data/public-hostname)
  if [ -z $AWS_HOST ]
  then
    echo "Kernel Gateway instance was started on port $PORT"
  else
    echo "Kernel Gateway URL: http://$AWS_HOST:$PORT"
  fi
}

function stopKernelGateway {
  kill -SIGTERM $(ps aux | grep jupyter-kernelgateway | grep -v grep | awk '{print $2}') > /dev/null 2>&1
  kill -SIGTERM $(ps aux | grep "/home/$USER/jupyter_data/runtime/kernel" | grep -v grep | awk '{print $2}') > /dev/null 2>&1
  echo "Kernel Gateway Server and Jupyter kernels were stopped"
}

function testKernelGateway {
  source ~/.bashrc
  kg_port=$1
  AUTHTOKEN=$KG_AUTH_TOKEN
  if [ -z $kg_port ]
  then
    echo "Enter Kernel Gateway port number, followed by [ENTER]:"
    read kg_port
  fi
  if [ -z $AUTHTOKEN ]
  then
    echo "Enter Kernel Gateway Authorization token, followed by [ENTER]:"
    read -s AUTHTOKEN
  fi
  resp_status=$(curl -o /dev/null --silent --write-out '%{http_code}' http://localhost:$kg_port/api/kernelspecs -H "Authorization: token $AUTHTOKEN")
  if [ $resp_status = "200" ]
  then
    echo "Kernel Gateway started"
    echo "Response from server: $resp_status"
  elif [ $resp_status = "401" ]
  then
    echo "Kernel Gateway test failed: Unauthorized request"
  elif [ $resp_status = "403" ]
  then
    echo "Kernel Gateway test failed: Access Forbidden. Incorrect authorization token provided."
  else
    echo "Kernel Gateway test failed with returned status code: $resp_status"
  fi
}

function restartKernelGateway {
  source ~/.bashrc
  stopKernelGateway
  startKernelGateway
}

function uninstallKernelGateway {
  stopKernelGateway
  yes | pip uninstall jupyter_kernel_gateway
  yes | pip uninstall ipython
  rm -r $WOKR_DIR
  rm $HOME/kg_log
  #TODO delete environment variables from .bashrc
  sed -i "/export KG_AUTH_TOKEN=/d" ~/.bashrc
  sed -i "/export JUPYTER_DATA_DIR=/d" ~/.bashrc
  echo "Kernel Gateway uninstalled successfully"
}

function createSparkUser {
  sparkuser=$1
  if [ -z $sparkuser ]
  then
    sparkuser=kernelgateway
  fi
  if grep $sparkuser /etc/passwd
  then
    echo "User $sparkuser already exist"
    exit
  fi
  sudo adduser $sparkuser
  sudo -u hdfs hadoop fs -mkdir /user/$sparkuser
  sudo -u hdfs hadoop fs -chown kernelgateway /user/$sparkuser
  echo "Spark user $sparkuser created"
}

function deleteUser {
  sparkuser=$1
  if [ -z $sparkuser ]
  then
    sparkuser=kernelgateway
  fi
  if grep $sparkuser /etc/passwd
  then
    sudo -u hdfs hadoop fs -rm /user/$sparkuser
    echo "Directory /user/$sparkuser deleted"
    userdel -r $sparkuser
    echo "User $sparkuser deleted"
    exit
  fi
}

while [[ $# -gt 0 ]]
do
key="$1"

case $key in
    -h|--help)
    echo "
    Install and run Kernel Gateway server on Amazon EMR cluster.
    Supported arguments:
    -r  --restart  Restart Kernel Gateway instance
    -s  --stop  Stop Kernel Gateway Instance and all associated kernels
    -t  --test  send test request to Kernel Gateway instance
    -U  --uninstall  Uninstall Kernel Gateway instance and delete all associated files and environment variables
    -H  --host  provide hostname
    -p  --port  Kernel Gateway port number
    -T  --token Kernel Gateway Authorization token
    "
    exit
    #shift # past argument
    ;;
    -r |--restart)
    restartKernelGateway
    exit
    ;;
    -t|--test)
    testKernelGateway
    exit
    ;;
    -U|--uninstall)
    uninstallKernelGateway
    exit
    ;;
    -s|--stop)
    stopKernelGateway
    exit
    ;;
    -H|--host)
    AWS_HOST="$2"
    shift
    ;;
    -p|--port)
    PORT="$2"
    shift
    ;;
    -T|--token)
    echo $2
    echo "export KG_AUTH_TOKEN=$2" >> ~/.bashrc
    shift # past argument
    ;;
    --createUser)
    createSparkUser $2
    exit
    ;;
    *)
            # unknown option
    ;;
esac
shift # past argument or value
done

setJupyterDataDir
setPortAndToken
installKernelGateway
createKernelsFolder
setupPySparkKernel
startKernelGateway
