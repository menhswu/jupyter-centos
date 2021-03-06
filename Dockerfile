################################################################################
# Setup builder stage OS
################################################################################
FROM centos:latest as builder

# Configure environment
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=100 \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH=$CONDA_DIR/bin:$PATH \
    HOME=/home/$NB_USER

# copy in necessary files
COPY util/* $CONDA_DIR/bin/

# initial installs using yum
USER root
RUN yum -y update \
    && yum -y install \
        curl \
        bzip2 \
        sudo \
        gcc \
        epel-release \
    && yum -y clean all

# create jovyan user with UID=1000 and in the 'users' group
# and make sure these dirs are writable by the `users` group.
RUN echo "### Creation of jovyan user account" \
    && useradd -m -s /bin/bash -N -u $NB_UID $NB_USER \
    && mkdir -p $CONDA_DIR \
    && chown -R $NB_USER:$NB_GID $CONDA_DIR \
    && chown -R $NB_USER:$NB_GID $HOME \
    && fix-permissions $HOME \
    && fix-permissions $CONDA_DIR \
    # grant user account sudo privilidge
    && echo "$NB_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/notebook

# miniconda installation
USER $NB_UID
COPY --chown=1000:100 config/jupyter $HOME/.jupyter/ 
#COPY --chown=1000:100 config/ipydeps $HOME/.config/ipydeps/
RUN curl -sSL https://repo.continuum.io/miniconda/Miniconda3-latest-Linux-x86_64.sh -o /tmp/miniconda.sh \
    && echo "### Installing miniconda" \
    && bash /tmp/miniconda.sh -bfp $CONDA_DIR \
    && rm -rf /tmp/miniconda.sh 

# core jupyter installation using conda
RUN conda update conda \
    && echo "### Installs using conda" \
    && conda install -y -c conda-forge \
        "python=3" \
        notebook \
        ipywidgets \
        tornado \
        jupyter_dashboards \
        jupyter_nbextensions_configurator \
        make \
        ruby \
    && conda clean --all --yes
  

# additional desired packages using pip
RUN echo "### Installs using pip" \
    && pip --no-cache-dir install \
        bash_kernel \
        jupyter_c_kernel==1.0.0 \
        ordo \
        pypki2 \
        ipydeps \
        jupyter_nbgallery

# Add simple kernels (no extra apks)
COPY kernels/installers/install_c_kernel $CONDA_DIR/share/jupyter/kernels/installers/
RUN echo "### Activate simple kernels" \
    && python -m bash_kernel.install --prefix=$CONDA_DIR \
    && python $CONDA_DIR/share/jupyter/kernels/installers/install_c_kernel --prefix=$CONDA_DIR \
    # Other pip package installation and enabling
    && echo "### Activate jupyter extensions" \
    && jupyter nbextensions_configurator enable --prefix=$CONDA_DIR \
    && jupyter nbextension enable --py --sys-prefix widgetsnbextension \
    && jupyter serverextension enable --py jupyter_nbgallery \
    && jupyter nbextension install --prefix=$CONDA_DIR --py jupyter_nbgallery \
    && jupyter nbextension enable jupyter_nbgallery --py \
    && jupyter nbextension install --prefix=$CONDA_DIR --py ordo \
    && jupyter nbextension enable ordo --py 

# Patches? Do we still need them? They go here 
RUN echo "### Patching" \
    && sed -i 's/_max_upload_size_mb = [0-9][0-9]/_max_upload_size_mb = 50/g' \
         $CONDA_DIR/lib/python3*/site-packages/notebook/static/tree/js/notebooklist.js \
         $CONDA_DIR/lib/python3*/site-packages/notebook/static/tree/js/main.min.js \
         $CONDA_DIR/lib/python3*/site-packages/notebook/static/tree/js/main.min.js.map 

# another last cleanup
RUN echo "### Final stage-one cleanup" \
    && conda clean --all --yes \ 
    # remove all compiled and test python files we can find
    && find $CONDA_DIR -name '*.py[co]' -delete \
    && find $CONDA_DIR -regex ".*/tests?" -type d -print0 | xargs -r0 -- rm -r ; exit 0

# add in all the dynamic kernels
COPY kernels/R_small $CONDA_DIR/share/jupyter/kernels/R_small
COPY kernels/R_big $CONDA_DIR/share/jupyter/kernels/R_big
COPY kernels/ruby $CONDA_DIR/share/jupyter/kernels/ruby
COPY kernels/python2 $CONDA_DIR/share/jupyter/kernels/python2
COPY kernels/javascript $CONDA_DIR/share/jupyter/kernels/javascript
COPY kernels/installers/dynamic* $CONDA_DIR/share/jupyter/kernels/installers/

################################################################################
# second stage
# - starts from scratch centos
# - copies in the /opt/conda and /home/jovyan directories
# - cleans up
################################################################################
FROM centos:latest
 
# Add Tini
ENV TINI_VERSION=v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini

# resetup ENV variables
ENV CONDA_DIR=/opt/conda \
    SHELL=/bin/bash \
    NB_USER=jovyan \
    NB_UID=1000 \
    NB_GID=100 \
    LC_ALL=en_US.UTF-8 \
    LANG=en_US.UTF-8 \
    LANGUAGE=en_US.UTF-8
ENV PATH=$CONDA_DIR/bin:$PATH \
    HOME=/home/$NB_USER \
    JUPYTER=/opt/conda/bin/jupyter 
ENV GOPATH=$HOME/.local/share/go \
    LGOPATH=$HOME/.local/share/lgo

# second stage install packages and cleanup
USER root
RUN yum -y update \
    && yum -y install \
        sudo \
        which \
        gcc \
        epel-release \
    && echo "### second layer cleanup" \
    && yum clean all \
    && rpm --rebuilddb \
    && rm -rf /var/cache/yum \
              /bin/bashbug \
              /usr/local/share/man/* \
              /usr/bin/gprof  \
    && find /usr/share/terminfo -type f -delete \
    && find / -name '*.py[co]' -delete \
    && chmod +x /tini \
    && echo "$NB_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/notebook \
    && echo "### Creation of jovyan user account" \
    && useradd -s /bin/bash -N -u $NB_UID $NB_USER \
    && rm -rf $HOME 

# copy in built package from base layer
COPY --chown=1000:100 --from=builder $CONDA_DIR $CONDA_DIR
COPY --chown=1000:100 --from=builder $HOME $HOME

# set startpoints
EXPOSE 80 443
ENTRYPOINT ["/tini", "--"]
USER $NB_UID
WORKDIR $HOME

# start notebook
CMD ["jupyter-notebook-secure"]


########################################################################
# Metadata
########################################################################
ENV NBGALLERY_CLIENT_VERSION=8.0.4

LABEL gallery.nb.version=$NBGALLERY_CLIENT_VERSION \
      gallery.nb.description="Centos-based Jupyter notebook server" \
      gallery.nb.URL="https://github.com/nbgallery/jupyter-centos" \
      maintainer="https://github.com/nbgallery"
