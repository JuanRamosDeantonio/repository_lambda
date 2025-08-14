import sys
import lambda_handler
import logging
import json

logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)

def main():

    try:

        logger.info("Inicia funcion main")

        evento = sys.argv[1]

        print(f"inicia main con argumento: {evento}")

        logger.info("inicia funcion main con evento: %s", evento)

        with open(evento, 'r') as file:
            evento = json.load(file)

        lambda_handler.lambda_handler(evento, 1)
    except Exception as e:
        print(f"Ocurrio un error, excepcion: {e}")
        #raise e

if __name__ == "__main__":
    main()