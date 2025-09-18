@EndUserText.label: 'File Transfer Parameters'
define type ZI_FileTransfer_Param {
  directory     : abap.char(255);
  file_name     : abap.char(128);
  target_url    : abap.char(512);
  proxy_host    : abap.char(255);
  proxy_service : abap.char(10);
  auth_user     : abap.char(60);
  auth_password : abap.char(60);
}

@EndUserText.label: 'File Transfer Requests'
@AccessControl.authorizationCheck: #CHECK
@Metadata.allowExtensions: true
@AbapCatalog.sqlViewName: 'ZVIFLTRNS'
define root view entity ZI_FileTransfer
  provider contract transactional_query
  as select from zfiletransfer
{
  key transfer_uuid      : abap.uuid,
      directory          : abap.char(255),
      file_name          : abap.char(128),
      target_url         : abap.char(512),
      last_http_status   : abap.int4,
      last_response_text : abap.string,
      last_executed_at   : abap.utclong
}


define behavior for ZI_FileTransfer alias FileTransfer
  persistent table zfiletransfer
  lock master
  authorization master ( instance )
  etag master last_executed_at
  managed implementation in class zbp_i_filetransfer unique
{
  create;
  update;
  delete;

  action sendToSFTP parameter ZI_FileTransfer_Param result [1] $self;

  mapping for zfiletransfer
  {
    transfer_uuid      = transfer_uuid;
    directory          = directory;
    file_name          = file_name;
    target_url         = target_url;
    last_http_status   = last_http_status;
    last_response_text = last_response_text;
    last_executed_at   = last_executed_at;
  }
}

CLASS zbp_i_filetransfer DEFINITION
  PUBLIC
  FINAL
  CREATE PUBLIC.
  PUBLIC SECTION.
    INTERFACES if_abap_behavior_handler.
ENDCLASS.

CLASS zbp_i_filetransfer IMPLEMENTATION.
ENDCLASS.

CLASS lhc_FileTransfer DEFINITION
  INHERITING FROM cl_abap_behavior_handler.
  PRIVATE SECTION.
    METHODS sendToSFTP
      FOR ACTION FileTransfer~sendToSFTP
      IMPORTING keys FOR ACTION FileTransfer~sendToSFTP
                parameter parameter
      RESULT result.
ENDCLASS.

CLASS lhc_FileTransfer IMPLEMENTATION.
  METHOD sendToSFTP.
    DATA ls_param TYPE ZI_FileTransfer_Param.
    ls_param = parameter.

    LOOP AT keys ASSIGNING FIELD-SYMBOL(<ls_key>).
      READ ENTITIES OF ZI_FileTransfer IN LOCAL MODE
        ENTITY FileTransfer
          FIELDS ( transfer_uuid directory file_name target_url last_http_status last_response_text last_executed_at )
          WITH VALUE #( ( %tky = <ls_key>-%tky ) )
        RESULT DATA(lt_transfer).

      IF lt_transfer IS INITIAL.
        APPEND VALUE #( %tky = <ls_key>-%tky
                        %msg = new_message_with_text( severity = if_abap_behv_message=>severity-error
                                                      text     = 'Transfer request not found.' ) )
          TO failed.
        CONTINUE.
      ENDIF.

      DATA(ls_transfer) = lt_transfer[ 1 ].

      DATA(lv_directory) = COND string( WHEN ls_param-directory IS NOT INITIAL THEN ls_param-directory ELSE ls_transfer-directory ).
      DATA(lv_file_name) = COND string( WHEN ls_param-file_name IS NOT INITIAL THEN ls_param-file_name ELSE ls_transfer-file_name ).
      DATA(lv_target_url) = COND string( WHEN ls_param-target_url IS NOT INITIAL THEN ls_param-target_url ELSE ls_transfer-target_url ).

      IF lv_directory IS INITIAL OR lv_file_name IS INITIAL OR lv_target_url IS INITIAL.
        APPEND VALUE #( %tky = <ls_key>-%tky
                        %msg = new_message_with_text( severity = if_abap_behv_message=>severity-error
                                                      text     = 'Directory, file name, and target URL are required.' ) )
          TO failed.
        CONTINUE.
      ENDIF.

      TRY.
          DATA(lv_status) = 0.
          DATA(lv_response) = ''.

          zcl_send_xml_http=>send_file_to_http(
            EXPORTING
              i_directory     = lv_directory
              i_file_name     = lv_file_name
              i_target_url    = lv_target_url
              i_proxy_host    = ls_param-proxy_host
              i_proxy_service = ls_param-proxy_service
              i_auth_user     = ls_param-auth_user
              i_auth_password = ls_param-auth_password
            IMPORTING
              e_http_status   = lv_status
              e_response_body = lv_response ).

          MODIFY ENTITIES OF ZI_FileTransfer IN LOCAL MODE
            ENTITY FileTransfer
              UPDATE FIELDS ( last_http_status last_response_text last_executed_at )
              WITH VALUE #( ( %tky             = <ls_key>-%tky
                              last_http_status   = lv_status
                              last_response_text = lv_response
                              last_executed_at   = cl_abap_context_info=>get_system_date_time( ) ) ).

          APPEND VALUE #( %tky = <ls_key>-%tky ) TO result.
          APPEND VALUE #( %tky = <ls_key>-%tky
                          %msg = new_message_with_text( severity = if_abap_behv_message=>severity-success
                                                        text     = |File { lv_file_name } forwarded to CPI (HTTP { lv_status }).| ) )
            TO reported.
        CATCH zcx_file_transfer_error INTO DATA(lx_transfer).
          MODIFY ENTITIES OF ZI_FileTransfer IN LOCAL MODE
            ENTITY FileTransfer
              UPDATE FIELDS ( last_http_status last_response_text last_executed_at )
              WITH VALUE #( ( %tky             = <ls_key>-%tky
                              last_http_status   = 0
                              last_response_text = lx_transfer->get_text( )
                              last_executed_at   = cl_abap_context_info=>get_system_date_time( ) ) ).

          APPEND VALUE #( %tky = <ls_key>-%tky
                          %msg = new_message_with_text( severity = if_abap_behv_message=>severity-error
                                                        text     = lx_transfer->get_text( ) ) )
            TO failed.
      ENDTRY.
    ENDLOOP.
  ENDMETHOD.
ENDCLASS.
