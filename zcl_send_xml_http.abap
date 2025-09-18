CLASS zcx_file_transfer_error DEFINITION
  PUBLIC
  INHERITING FROM cx_static_check
  FINAL.
  PUBLIC SECTION.
    METHODS constructor
      IMPORTING
        msg      TYPE string OPTIONAL
        previous TYPE REF TO cx_root OPTIONAL.
ENDCLASS.

CLASS zcx_file_transfer_error IMPLEMENTATION.
  METHOD constructor.
    super->constructor( previous = previous ).
    IF msg IS INITIAL AND previous IS BOUND.
      me->set_text( previous->get_text( ) ).
    ELSEIF msg IS NOT INITIAL.
      me->set_text( msg ).
    ELSE.
      me->set_text( 'File transfer error occurred.' ).
    ENDIF.
  ENDMETHOD.
ENDCLASS.

CLASS zcl_send_xml_http DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.
  PUBLIC SECTION.
    CONSTANTS c_content_type_xml TYPE string VALUE 'application/xml'.
    CLASS-METHODS send_file_to_http
      IMPORTING
        i_directory     TYPE string
        i_file_name     TYPE string
        i_target_url    TYPE string
        i_proxy_host    TYPE string OPTIONAL
        i_proxy_service TYPE string OPTIONAL
        i_auth_user     TYPE string OPTIONAL
        i_auth_password TYPE string OPTIONAL
      EXPORTING
        e_http_status   TYPE i
        e_response_body TYPE string
      RAISING
        zcx_file_transfer_error.
  PROTECTED SECTION.
  PRIVATE SECTION.
    CLASS-METHODS normalize_directory
      IMPORTING
        i_directory TYPE string
      RETURNING VALUE(r_directory) TYPE string.
ENDCLASS.

CLASS zcl_send_xml_http IMPLEMENTATION.
  METHOD normalize_directory.
    DATA(lv_directory) = cl_abap_string_utilities=>trim( val = i_directory ).
    IF lv_directory IS INITIAL.
      r_directory = ''.
      RETURN.
    ENDIF.

    DATA(lv_len) = strlen( lv_directory ).
    IF lv_len = 0.
      r_directory = ''.
    ELSEIF lv_directory+lv_len-1 = '/'.
      r_directory = lv_directory.
    ELSE.
      r_directory = |{ lv_directory }/|.
    ENDIF.
  ENDMETHOD.

  METHOD send_file_to_http.
    IF i_directory IS INITIAL OR i_file_name IS INITIAL OR i_target_url IS INITIAL.
      RAISE EXCEPTION NEW zcx_file_transfer_error(
        msg = 'Directory, file name, and target URL must be provided.' ).
    ENDIF.

    DATA(lv_directory) = normalize_directory( i_directory = i_directory ).
    DATA(lv_full_path) = |{ lv_directory }{ i_file_name }|.

    DATA: lv_payload_line TYPE string,
          lv_payload      TYPE string,
          lv_message      TYPE string.

    OPEN DATASET lv_full_path FOR INPUT IN TEXT MODE ENCODING UTF-8 MESSAGE lv_message.
    IF sy-subrc <> 0.
      RAISE EXCEPTION NEW zcx_file_transfer_error(
        msg = |Unable to open file { lv_full_path }: { lv_message }| ).
    ENDIF.

    TRY.
        WHILE abap_true.
          READ DATASET lv_full_path INTO lv_payload_line.
          IF sy-subrc <> 0.
            EXIT.
          ENDIF.

          IF lv_payload IS INITIAL.
            lv_payload = lv_payload_line.
          ELSE.
            CONCATENATE lv_payload cl_abap_char_utilities=>newline lv_payload_line INTO lv_payload.
          ENDIF.
        ENDWHILE.
      CATCH cx_sy_file_access_error INTO DATA(lx_file).
        CLOSE DATASET lv_full_path.
        RAISE EXCEPTION NEW zcx_file_transfer_error( previous = lx_file ).
    ENDTRY.

    CLOSE DATASET lv_full_path.

    IF lv_payload IS INITIAL.
      RAISE EXCEPTION NEW zcx_file_transfer_error(
        msg = |File { lv_full_path } is empty.| ).
    ENDIF.

    DATA(lo_http_client) TYPE REF TO if_http_client.

    TRY.
        cl_http_client=>create_by_url(
          EXPORTING
            url           = i_target_url
            proxy_host    = i_proxy_host
            proxy_service = i_proxy_service
          IMPORTING
            client        = lo_http_client ).
      CATCH cx_root INTO DATA(lx_create).
        RAISE EXCEPTION NEW zcx_file_transfer_error( previous = lx_create ).
    ENDTRY.

    TRY.
        lo_http_client->request->set_method( if_http_request=>co_request_method_post ).
        lo_http_client->request->set_header_field( name = if_http_header_fields_sap=>content_type value = c_content_type_xml ).
        lo_http_client->request->set_header_field( name = if_http_header_fields_sap=>accept value = c_content_type_xml ).

        IF i_auth_user IS NOT INITIAL.
          lo_http_client->authenticate( username = i_auth_user password = i_auth_password ).
        ENDIF.

        lo_http_client->request->set_cdata( data = lv_payload ).

        lo_http_client->send( ).
        lo_http_client->receive( ).

        lo_http_client->response->get_status( IMPORTING code = e_http_status ).
        e_response_body = lo_http_client->response->get_cdata( ).

        IF e_http_status < 200 OR e_http_status >= 300.
          DATA(lv_reason) = lo_http_client->response->get_status_text( ).
          RAISE EXCEPTION NEW zcx_file_transfer_error(
            msg = |HTTP error { e_http_status } ({ lv_reason }) while calling { i_target_url }.| ).
        ENDIF.
      CATCH cx_root INTO DATA(lx_http).
        RAISE EXCEPTION NEW zcx_file_transfer_error( previous = lx_http ).
      FINALLY.
        IF lo_http_client IS BOUND.
          lo_http_client->close( ).
        ENDIF.
    ENDTRY.
  ENDMETHOD.
ENDCLASS.
