# Auto-generated MCP handlers
import json
import inspect
import re
from utils.types import Result
from utils.result import error_result

# Service instance singleton pattern
_api_service_instance = None

def get_api_service():
    global _api_service_instance
    if _api_service_instance is None:
        from mcp.services.api_service import api_service
        _api_service_instance = api_service
    return _api_service_instance

def camel_to_snake(name):
    """Convert camelCase to snake_case"""
    s1 = re.sub("(.)([A-Z][a-z]+)", r"\1_\2", name)
    return re.sub("([a-z0-9])([A-Z])", r"\1_\2", s1).lower()

def get_nodes(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_nodes
    """
    try:
        print(f"[DEBUG] Handler 'get_nodes' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_nodes", None)
        if not callable(service_method):
            return error_result("Service method 'get_nodes' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_nodes' failed: {str(e)}")
def create_node(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: create_node
    """
    try:
        print(f"[DEBUG] Handler 'create_node' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "create_node", None)
        if not callable(service_method):
            return error_result("Service method 'create_node' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'create_node' failed: {str(e)}")
def delete_node(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: delete_node
    """
    try:
        print(f"[DEBUG] Handler 'delete_node' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "delete_node", None)
        if not callable(service_method):
            return error_result("Service method 'delete_node' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'delete_node' failed: {str(e)}")
def get_node_detail(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_node_detail
    """
    try:
        print(f"[DEBUG] Handler 'get_node_detail' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_node_detail", None)
        if not callable(service_method):
            return error_result("Service method 'get_node_detail' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_node_detail' failed: {str(e)}")
def update_node(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: update_node
    """
    try:
        print(f"[DEBUG] Handler 'update_node' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "update_node", None)
        if not callable(service_method):
            return error_result("Service method 'update_node' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'update_node' failed: {str(e)}")
def get_node_errors(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_node_errors
    """
    try:
        print(f"[DEBUG] Handler 'get_node_errors' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_node_errors", None)
        if not callable(service_method):
            return error_result("Service method 'get_node_errors' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_node_errors' failed: {str(e)}")
def get_td_python_classes(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_td_python_classes
    """
    try:
        print(f"[DEBUG] Handler 'get_td_python_classes' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_td_python_classes", None)
        if not callable(service_method):
            return error_result("Service method 'get_td_python_classes' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_td_python_classes' failed: {str(e)}")
def get_td_python_class_details(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_td_python_class_details
    """
    try:
        print(f"[DEBUG] Handler 'get_td_python_class_details' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_td_python_class_details", None)
        if not callable(service_method):
            return error_result("Service method 'get_td_python_class_details' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_td_python_class_details' failed: {str(e)}")
def get_module_help(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_module_help
    """
    try:
        print(f"[DEBUG] Handler 'get_module_help' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_module_help", None)
        if not callable(service_method):
            return error_result("Service method 'get_module_help' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_module_help' failed: {str(e)}")
def exec_node_method(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: exec_node_method
    """
    try:
        print(f"[DEBUG] Handler 'exec_node_method' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "exec_node_method", None)
        if not callable(service_method):
            return error_result("Service method 'exec_node_method' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'exec_node_method' failed: {str(e)}")
def exec_python_script(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: exec_python_script
    """
    try:
        print(f"[DEBUG] Handler 'exec_python_script' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "exec_python_script", None)
        if not callable(service_method):
            return error_result("Service method 'exec_python_script' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'exec_python_script' failed: {str(e)}")
def get_td_info(body: str = None, **kwargs) -> Result:
    """
    Auto-generated handler for operation: get_td_info
    """
    try:
        print(f"[DEBUG] Handler 'get_td_info' called with body: {body}, kwargs: {kwargs}")
        service_method = getattr(get_api_service(), "get_td_info", None)
        if not callable(service_method):
            return error_result("Service method 'get_td_info' not implemented")

        # Merge body
        if body:
            try:
                parsed_body = json.loads(body)
                kwargs.update(parsed_body)
            except Exception as e:
                return error_result(f"Invalid JSON body: {str(e)}")

        # CamelCase → SnakeCase 変換
        kwargs_snake_case = {camel_to_snake(k): v for k, v in kwargs.items()}

        sig = inspect.signature(service_method)

        # Prepare args matching the function signature
        call_args = {}
        for param_name in sig.parameters:
            if param_name in kwargs_snake_case:
                call_args[param_name] = kwargs_snake_case[param_name]

        return service_method(**call_args)

    except Exception as e:
        return error_result(f"Handler for 'get_td_info' failed: {str(e)}")

__all__ = [
  "get_nodes",
  "create_node",
  "delete_node",
  "get_node_detail",
  "update_node",
  "get_node_errors",
  "get_td_python_classes",
  "get_td_python_class_details",
  "get_module_help",
  "exec_node_method",
  "exec_python_script",
  "get_td_info",
]
