#!/usr/bin/bash 

########################################################################
# a simple script to do key/value pair replacement in Koha and
# Koha-Docker's .env files.
########################################################################

# Exit immediately if a command exits with a non-zero status
set -e

# FIXME: should we pass in or overwrite the location name?
JSON_FILE="env/.env.json"

########################################################################
# ENV helper functions
########################################################################

########################################################################
# If the cached JSON .env files exists, read in all the names of the
# template and .env files
########################################################################
read_env_file() {
    if [ ! -f "$JSON_FILE" ]; then
        echo "Error: File '$JSON_FILE' does not exist."
        exit 1
    fi
    echo $(<$1)
}

# $1 = JSON string
# $2 = ENV variable
# $3 = some default value if the ENV variable does not exist
get_env_pair() {
    local ret
    ret=$(echo $1 | jq -r --arg k "$2" '.[$k]')
    if [[ -n $ret && $ret != "null" ]]; then
        echo $ret
    else
        if [[ -n $3 ]]; then
           echo $3
        else
           echo ""
        fi
    fi
}

# $1 = JSON string
# $2 = kv_pair key
# $3 = kv_pair subkey
get_kv_pair() {
    echo $(echo $1 | jq --arg k "$2" --arg s "$3" -r '.kv_pairs.[$k].[$s]')
}

# $1 = JSON string
# $2 = key 
# $3 = subkey
# $4 = new value
set_kv_pairs() {
    local mstr="$1"
    local key="$2"
    local subkey="$3"
    local value="$4"

    echo $(echo $mstr | jq --arg k "$key" --arg s "$subkey" --arg v "$value" '.kv_pairs.[$k].[$s] = $v')
}

JSON_data=$(read_env_file $JSON_FILE)

ENV_TMPL_FILE=$(get_env_pair "$JSON_data" "ENV_TMPL_FILE")
echo "ENV_TMPL_FILE=$ENV_TMPL_FILE"

ENV_TMPL_FILE2=$(get_env_pair "$JSON_data" "ENV_TMPL_FILE2" "some dfault")
echo "ENV_TMPL_FILE2='$ENV_TMPL_FILE2'"

#ENV_TMPL_FILE=$(jq -r '.ENV_TMPL_FILE' "$JSON_FILE")
#ENV_FILE=$(jq -r '.ENV_FILE' "$JSON_FILE")
#OS_ENV_TMPL_FILE=$(jq -r '.OS_ENV_TMPL_FILE' "$JSON_FILE")
#OS_ENV_FILE=$(jq -r '.OS_ENV_FILE' "$JSON_FILE")
#OS_DASH_TMPL_FILE=$(jq -r '.OS_DASH_TMPL_FILE' "$JSON_FILE")
#OS_DASH_FILE=$(jq -r '.OS_DASH_FILE' "$JSON_FILE")


ENV_TMPL_FILE=$(jq -r '.ENV_TMPL_FILE' "$JSON_FILE")
ENV_FILE=$(jq -r '.ENV_FILE' "$JSON_FILE")
OS_ENV_TMPL_FILE=$(jq -r '.OS_ENV_TMPL_FILE' "$JSON_FILE")
OS_ENV_FILE=$(jq -r '.OS_ENV_FILE' "$JSON_FILE")
OS_DASH_TMPL_FILE=$(jq -r '.OS_DASH_TMPL_FILE' "$JSON_FILE")
OS_DASH_FILE=$(jq -r '.OS_DASH_FILE' "$JSON_FILE")

########################################################################
# read in the key pairs, description, and default values.
########################################################################

ENV_TMPL_FILE=$(jq -r '.ENV_TMPL_FILE' "$JSON_FILE")
ENV_FILE=$(jq -r '.ENV_FILE' "$JSON_FILE")
OS_ENV_TMPL_FILE=$(jq -r '.OS_ENV_TMPL_FILE' "$JSON_FILE")
OS_ENV_FILE=$(jq -r '.OS_ENV_FILE' "$JSON_FILE")
OS_DASH_TMPL_FILE=$(jq -r '.OS_DASH_TMPL_FILE' "$JSON_FILE")
OS_DASH_FILE=$(jq -r '.OS_DASH_FILE' "$JSON_FILE")


result1=$(read_env_file $JSON_FILE)
#echo "from file is: $result1"
#echo ""


# pass the contents of the $JSON_FILE to set_kv_pairs and modify the results
result2=$(set_kv_pairs "$result1" "SYNC_REPO" "user_val" "aosudhoiqjwoinqwcx")
echo "New value is: $result2"
#echo ""

# replace the value of the user value for "OS_DASH_FILE"
#result3=$(set_kv_pairs "$result2" "OS_DASH_FILE" "user_val" "blablabla")
#echo "Mod value is: $result3"

#kv_SYNC_REPO=$(get_kv_pair "$result1" "SYNC_REPO" "user_val")
#echo "kv_SYNC_REPO=$kv_SYNC_REPO"

########################################################################
# replace expected values
########################################################################

# cp $tmpl_file $env_file
# sed -i 's|%%SYNC_REPO%%|${NEW_TEXT}|g' "$env_file"



exit 0
########################################################################
# key value pairs
########################################################################
kv_pairs = {
    # manditory changes
    "SYNC_REPO":{
        "value":"%%SYNC_REPO%%",
        "description":"absolute path to your local koha-docker/koha",
        "default_val":"./koha",
        "user_val":None,
        "abs_path":True
    },
    
    "KOHA_DB_ROOT_PASSWORD":{
        "value":"%%KOHA_DB_ROOT_PASSWORD%%",
        "description":"<something>",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "KOHA_DB_PASSWORD":{
        "value":"%%KOHA_DB_PASSWORD%%",
        "description":"<something>",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "KOHA_ADMIN_PASSWORD":{
        "value":"%%KOHA_ADMIN_PASSWORD%%",
        "description":"<something>",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "KOHA_PASS":{
        "value":"%%KOHA_PASS%%",
        "description":"<something>",
        "default_val":"koha",
        "user_val":None,
        "abs_path":False
    },
    "KOHA_DOMAIN":{
        "value":"%%KOHA_DOMAIN%%",
        "description":"<something>",
        "default_val":".127.0.0.1.nip.io",
        "user_val":None,
        "abs_path":False
    },
    "OPENSEARCH_INITIAL_ADMIN_PASSWORD":{
        "value":"%%OPENSEARCH_INITIAL_ADMIN_PASSWORD%%",
        "description":"<something>",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },

    ###########
    # fundamental environmental files
    "KOHA_DOCKER":{
        "value":"%%KOHA_DOCKER%%",
        "description":"absolute path to your local koha-docker/koha",
        "default_val":".",
        "user_val":None,
        "abs_path":True
    },
    "ENV_TMPL_FILE":{
        "value":"%%ENV_TMPL_FILE%%",
        "description":"absolute path to your local koha-docker/env/wizard_tmpl.env",
        "default_val":"./env/wizard_tmpl.env",
        "user_val":None,
        "abs_path":True
    },
    "ENV_FILE":{
        "value":"%%ENV_FILE%%",
        "description":"absolute path to your local koha-docker/env/.env",
        "default_val":"./env/.env",
        "user_val":None,
        "abs_path":True
    },
    "OS_ENV_TMPL_FILE":{
        "value":"%%ENV_TMPL_FILE%%",
        "description":"absolute path to your local koha-docker/env/OS_wizard_tmpl.env",
        "default_val":"./OpenSearch-3.6/OS_wizard_tmpl.env",
        "user_val":None,
        "abs_path":True
    },
    "OS_ENV_FILE":{
        "value":"%%ENV_FILE%%",
        "description":"absolute path to your local koha-docker/env/template.env.new",
        "default_val":"./OpenSearch-3.6/.env",
        "user_val":None,
        "abs_path":True
    },
    "OS_DASH_TMPL_FILE":{
        "value":"%%OS_DASH_TMPL_FILE%%",
        "description":"absolute path to your local opensearch_dashboards.yml template file",
        "default_val":"./OpenSearch-3.6/assets/dashboards/OS_tmpl_opensearch_dashboards.yml",
        "user_val":None,
        "abs_path":True
    },
    "OS_DASH_FILE":{
        "value":"%%OS_DASH_FILE%%",
        "description":"absolute path to your local opensearch_dashboards.yml file",
        "default_val":"./OpenSearch-3.6/assets/dashboards/opensearch_dashboards.yml",
        "user_val":None,
        "abs_path":True
    },
}

extended_pairs = {
    # manditory changes
    "GIT_BZ_PASSWORD":{
        "value":"%%GIT_BZ_PASSWORD%%",
        "description":"git bz password [FIXME: why is this needed?]",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "GIT_BZ_USER":{
        "value":"%%GIT_BZ_USER%%",
        "description":"git bz user",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "GIT_USER_EMAIL":{
        "value":"%%GIT_BZ_EMAIL%%",
        "description":"git email",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "GIT_USER_NAME":{
        "value":"%%GIT_USER_NAME%%",
        "description":"git user name",
        "default_val":None,
        "user_val":None,
        "abs_path":False
    },
    "KEYCLOAK_ADMIN_PASS":{
        "value":"%%KEYCLOAK_ADMIN_PASS%%",
        "description":"keycloak_admin_password",
        "default_val":"keycloak",
        "user_val":None,
        "abs_path":False
    },
}
###############################################################################
# see if any of the values are set in the environment, and set the defaults
###############################################################################

#for k in kv_pairs.keys():
#    kv_pairs[k]["user_val"] = os.getenv(k, kv_pairs[k]["default_val"])
    #print(k, kv_pairs[k]["default_val"], kv_pairs[k]["user_val"])

###KOHA_HOME = os.getenv('KOHA_HOME',
###                      '/'.join([KOHA_DOCKER,"koha"])) # default in instructions

# FIXME: what is the best way to set the defaults.
###KOHA_DOMAIN =  os.getenv('KOHA_DOCKER', '.127.0.0.1.nip.io')

KOHA_DOCKER = os.getenv('KOHA_DOCKER',
                        kv_pairs["KOHA_DOCKER"]["user_val"])
ENV_FILE = os.getenv('ENV_FILE',
                     kv_pairs["ENV_FILE"]["default_val"])
ENV_TMPL_FILE = os.getenv('ENV_TMPL_FILE',
                          kv_pairs["ENV_TMPL_FILE"]["default_val"])
OS_ENV_FILE = os.getenv('OS_ENV_FILE',
                        kv_pairs["OS_ENV_FILE"]["default_val"])
OS_ENV_TMPL_FILE = os.getenv('OS_ENV_TMPL_FILE',
                             kv_pairs["OS_ENV_TMPL_FILE"]["default_val"])
OS_DASH_FILE = os.getenv('OS_DASH_FILE',
                        kv_pairs["OS_DASH_FILE"]["default_val"])
OS_DASH_TMPL_FILE = os.getenv('OS_DASH_TMPL_FILE',
                             kv_pairs["OS_DASH_TMPL_FILE"]["default_val"])

overwrite = False
overwrite_test = False
def key_val_replace(tmpl_file,env_file):
    global kv_pairs
    global overwrite, overwrite_test
    if not os.path.exists(tmpl_file):
        logging.error(f"Koha Docker ENV file '{env_file}' does not exist.")
        exit(-1)
    if os.path.exists(env_file) and overwrite_test==False:
        overwrite_test = True
        response = input(f"Koha Docker ENV file '{env_file}' exists. Do you want to overwrite? (y/[n]): ").strip().lower()
                
        if response=="": response='n' # the default
        if response[0]=='n' and response[0]=='N':
            logger.info(f"   ... skiping")
            return

    overwrite = True
    overwrite_test = True
    lines = []
    with open(tmpl_file,'r') as fin:
        lines = fin.readlines()
    # now process the keys
    with open(env_file,'w') as fout:
        for l in lines:
            #for idx,k in enumerate(kv_pairs):
            for k in kv_pairs:
                if  kv_pairs[k]["value"] in l:
                    if kv_pairs[k]["user_val"] == None:
                        if kv_pairs[k]["default_val"] == None:
                            response = input(f'   new vaule for {k}: ').strip()
                        else:
                            response = input(f'   new vaule for {k} (default:{kv_pairs[k]["default_val"]}): ').strip()
                            if response =='':
                                response = kv_pairs[k]["default_val"]
                                
                        if kv_pairs[k]["abs_path"]:
                            from pathlib import Path
                            response = str(Path(response).resolve())
                    else:
                        response = kv_pairs[k]["user_val"]

                    if '' != response:
                        l = l.replace(kv_pairs[k]["value"],response)
                        kv_pairs[k]["user_val"] = response
                    else:
                        # FIXME: should we do anything with this?
                        print("**** nil")
                    
            # FIXME: should also set something so that I do not have
            # to redo on every file...
            logger.debug(f"sub: {l.strip()}")
            fout.write(l)


if __name__ == "__main__":
    import argparse

    prog = os.path.basename(__file__)
    
    parser = argparse.ArgumentParser(prog=prog,
                                     description="setup koha-docker and koha's .env files.")

    parser.add_argument("-C","--config", action="store_true",
                        help="Cache the config information.")
    parser.add_argument("-E","--extended", action="store_true",
                        help="Process the 'extended' list of environmental variables.")
    parser.add_argument("-F", "--config-file", type=str, default='env/.env.json',
                        help='Set the env cache file (default: %(default)s)')

    parser.add_argument("-l", "--log", default='WARNING', required=False,
                        choices=['DEBUG', 'INFO', 'WARNING', 'ERROR', 'CRITICAL'],
                        help='Set the logging level (default: %(default)s)')

    args = parser.parse_args()

    # check to see if I should process the extended env variables
    if args.extended:
        kv_pairs |= extended_pairs

    # read in the convif if it exists.
    if args.config:
        logger.info(f"reading config file '{args.config_file}'")
        if os.path.exists(args.config_file):
            response = input(f"Cached ENV file '{args.config_file}' exists. Do you want to use the cached values? ([y]/n): ").strip().lower()
            if response=="": response='y' # the default
            if response[0]!='n' and response[0]!='N':
                with open(args.config_file, "r") as json_file:
                    econfig = json.load(json_file)

                ###KOHA_DOCKER = econfig["KOHA_DOCKER"]
                ###KOHA_HOME = econfig["KOHA_HOME"]
                ###KOHA_DOMAIN =  econfig["KOHA_DOCKER"]

                #KOHA_DOCKER_ENV = econfig["KOHA_DOCKER_ENV"]
                ENV_TMPL_FILE = econfig["ENV_TMPL_FILE"]
                ENV_FILE = econfig["ENV_FILE"]
                OS_ENV_TMPL_FILE = econfig["OS_ENV_TMPL_FILE"]
                OS_ENV_FILE = econfig["OS_ENV_FILE"]
                OS_DASH_TMPL_FILE = econfig["OS_DASH_TMPL_FILE"]
                OS_DASH_FILE = econfig["OS_DASH_FILE"]

                kv_pairs = econfig["kv_pairs"]

    # setup the logger and report FIXME...
    logging.basicConfig(level=args.log,handlers=[logging.StreamHandler()])

    ###logger.debug(f" KOHA_HOME = {KOHA_HOME}")
    ###logger.debug(f" KOHA_DOCKER = {KOHA_DOCKER}")
    #logger.debug(f" KOHA_DOCKER_ENV = {KOHA_DOCKER_ENV}")
    logger.debug(f" ENV_TMPL_FILE = {ENV_TMPL_FILE}")
    logger.debug(f" ENV_FILE = {ENV_FILE}")
    logger.debug(f" OS_ENV_TMPL_FILE = {OS_ENV_TMPL_FILE}")
    logger.debug(f" OS_ENV_FILE = {OS_ENV_FILE}")
    logger.debug(f"")

    key_val_replace(ENV_TMPL_FILE,ENV_FILE)
    key_val_replace(OS_ENV_TMPL_FILE,OS_ENV_FILE)
    key_val_replace(OS_DASH_TMPL_FILE,OS_DASH_FILE)

    # read in the convif if it exists.
    if args.config:
        econfig = {
            ###"KOHA_DOCKER":KOHA_DOCKER,
            ###"KOHA_HOME":KOHA_HOME,
            ###"KOHA_DOMAIN":KOHA_DOCKER,

            #"KOHA_DOCKER_ENV":KOHA_DOCKER_ENV,
            "ENV_TMPL_FILE":ENV_TMPL_FILE,
            "ENV_FILE":ENV_FILE,
            "OS_ENV_TMPL_FILE":OS_ENV_TMPL_FILE,
            "OS_ENV_FILE":OS_ENV_FILE,
            "OS_DASH_TMPL_FILE":OS_DASH_TMPL_FILE,
            "OS_DASH_FILE":OS_DASH_FILE,

            "kv_pairs":kv_pairs
        }

        with open(args.config_file, "w") as json_file:
            json.dump(econfig, json_file, indent=4) 
